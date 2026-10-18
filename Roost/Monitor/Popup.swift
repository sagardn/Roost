import AppKit

/// The floating panel a menu bar reading opens into.
///
/// Built as an NSPanel for the same reason SearchPanel is: an NSMenu runs its
/// own event-tracking loop and a hosted view inside it never gets proper
/// keyboard or scroll handling. A panel is a real window, so the content can
/// scroll, take clicks and hold focus.
///
/// One of these per module, created lazily and kept, so chart history and
/// scroll position survive being closed and reopened.
extension ReadingPopup: MenuHostingWindow {}

final class ReadingPopup: NSPanel {

    private let content: PopupContent
    private let header: PopupHeader
    private let scroll = NSScrollView()
    private let body = NSStackView()

    /// Watches for a click anywhere outside. resignKey covers most of it, but
    /// not every way focus can move, so this is the backstop that makes
    /// "click away and it goes" always true -- the same approach SearchPanel
    /// settled on.
    private var outsideClickMonitor: Any?
    private var tick: Timer?

    /// Suppresses the outside-click dismissal while a menu of our own is up,
    /// which costs the panel key status without the user having clicked away.
    var isShowingOwnMenu = false

    private let width = PopupMetrics.windowWidth
    private let maxHeight: CGFloat = 620
    private let gapUnderMenuBar: CGFloat = 6

    init(content: PopupContent) {
        self.content = content
        self.header = PopupHeader(title: content.title)

        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                   // .nonactivatingPanel, unlike SearchPanel: this one is
                   // read-only, and a menu bar readout must not pull you out
                   // of the app you are working in. The panel can still take
                   // key status for Escape; what it must not do is activate
                   // Roost.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        contentView = background

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 12, left: PopupMetrics.inset,
                                      bottom: 14, right: PopupMetrics.inset)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(content.makeView())

        // An NSClipView is not flipped, so a stack view inside one lays out
        // from the bottom and the popup opened already scrolled past its own
        // headline. This container puts the origin at the top.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        scroll.drawsBackground = false
        // No scroller. A popup this narrow had a third of its right margin
        // taken by a bar that only said "there is more below", which the
        // content running off the bottom edge already says. It still
        // scrolls with a trackpad or wheel.
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onSettings = { [weak self] in self?.showSettings() }
        background.addSubview(header)
        background.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PopupHeader.height),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            body.widthAnchor.constraint(equalToConstant: width)
        ])
    }

    // MARK: - Showing

    /// `anchor` is the status item button's frame in screen coordinates. The
    /// popup hangs under it, nudged back on screen if the item sits near a
    /// corner.
    func show(below anchor: NSRect) {
        guard !isVisible else { return }

        content.willShow()
        content.refresh()
        resize()

        var origin = NSPoint(x: anchor.midX - frame.width / 2,
                             y: anchor.minY - frame.height - gapUnderMenuBar)

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                        ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        setFrameOrigin(origin)

        makeKeyAndOrderFront(nil)
        // Always open at the top, however far it was scrolled last time.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        watchForOutsideClick()

        // One timer, only while visible. Modules that need something slower
        // than this throttle it themselves.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.content.refresh()
            self.resize()
        }
        tick?.tolerance = 0.2
    }

    func hide() {
        guard isVisible else { return }
        tick?.invalidate()
        tick = nil
        stopWatchingForOutsideClick()
        orderOut(nil)
        content.didHide()
        // Somebody just read a popup and closed it, which is the clearest
        // signal the app ever gets that the person is at the Mac and has
        // finished looking at something. The support window waits for it.
        NotificationCenter.default.post(name: .popupVisibilityChanged,
                                        object: nil, userInfo: ["state": false])
    }

    func toggle(below anchor: NSRect) {
        isVisible ? hide() : show(below: anchor)
    }

    /// The content grows as history fills in and as process rows come and go,
    /// so the window is measured on every tick rather than once on open.
    private func resize() {
        // Rows that arrive after the popup opens -- the process list, which
        // waits on ps -- grew the document and carried the view down with
        // it: a popup opened at the top was a hundred points past its own
        // status line five seconds later. Pinned to the top unless the user
        // has scrolled away from it.
        let wasAtTop = scroll.contentView.bounds.minY <= 1
        defer {
            if wasAtTop, scroll.contentView.bounds.minY > 1 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        body.layoutSubtreeIfNeeded()
        let wanted = body.fittingSize.height + PopupHeader.height
        let height = min(wanted, maxHeight)
        guard abs(height - frame.height) > 0.5 else { return }

        // Grow downwards from the top edge, so the popup stays pinned under
        // the menu bar instead of walking up the screen.
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: width, height: height),
                 display: true)
    }

    // MARK: - Dismissal

    override var canBecomeKey: Bool { true }

    /// A right-click anywhere in the popup gives the same menu the menu bar
    /// reading does. The popup is where somebody is already looking when
    /// they want Settings or Quit, and a window that answers a right-click
    /// with nothing reads as a window that is not finished.
    ///
    /// Rows that have a menu of their own -- a process offering Quit and
    /// Force Quit -- handle the click before it reaches here, because the
    /// view under the pointer is asked first.
    override func rightMouseDown(with event: NSEvent) {
        let pane = content is CombinedDetails ? "Dashboard" : content.title
        let menu = AppMenu.make(for: pane)
        // Without this the popup treats the menu opening as a click
        // elsewhere and closes underneath it.
        isShowingOwnMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? NSView())
        isShowingOwnMenu = false
    }

    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    override func resignKey() {
        super.resignKey()
        guard !isShowingOwnMenu else { return }
        hide()
    }

    private func watchForOutsideClick() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.isShowingOwnMenu else { return }
            self.hide()
        }
    }

    private func stopWatchingForOutsideClick() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        tick?.invalidate()
    }

    // MARK: - Settings

    private func showSettings() {
        // No module supplies an inline view: their settings are full pages in
        // the Settings window, so the gear opens that page. Returning here
        // instead left a visible gear that did nothing when clicked.
        guard let view = content.settingsView() else {
            hide()
            // The panel is non-activating, so Roost is usually in the
            // background when the gear is clicked, and the Settings window
            // would open behind the frontmost app without this.
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            // The combined popup's title is localized, so it cannot be matched
            // against the English pane name the window maps it to.
            let pane = content is CombinedDetails ? "Dashboard" : content.title
            NotificationCenter.default.post(name: .toggleSettings, object: nil,
                                            userInfo: ["module": pane])
            return
        }
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)

        isShowingOwnMenu = true
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 8, y: PopupHeader.height),
                   in: contentView)
        isShowingOwnMenu = false
    }
}

/// Title in the middle, the module's own controls on the left. Identical for
/// every module, so a new one gets it for nothing.
final class PopupHeader: NSView {

    static let height: CGFloat = 38

    /// Nothing sets this yet, so the chart button stays hidden until
    /// something does. It was shown unconditionally, and clicking it did
    /// nothing in every popup.
    var onChartToggle: (() -> Void)? {
        didSet { chartButton?.isHidden = onChartToggle == nil }
    }
    var onSettings: (() -> Void)?

    private weak var chartButton: NSButton?

    init(title: String) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let chart = Self.button("chart.line.uptrend.xyaxis", localized("Show or hide the charts"))
        chart.target = self
        chart.action = #selector(chartClicked)
        chart.isHidden = true

        let gear = Self.button("gearshape", localized("Open this module's settings"))
        gear.target = self
        gear.action = #selector(settingsClicked)

        chartButton = chart
        let controls = NSStackView(views: [chart, gear])
        controls.spacing = 2
        controls.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(controls)
        addSubview(rule)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: controls.trailingAnchor,
                                           constant: 8),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func chartClicked() { onChartToggle?() }
    @objc private func settingsClicked() { onSettings?() }

    private static func button(_ symbol: String, _ tooltip: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }
}

/// A container whose origin is the top left, so content inside a scroll view
/// stacks downwards the way every other list on the platform does.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
