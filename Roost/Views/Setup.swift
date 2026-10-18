import AppKit

/// The window somebody sees once, the first time Roost runs.
///
/// Five pages: a welcome, a choice of what goes in the menu bar, whether to
/// start at login, how often to check for updates, and a goodbye. `Startup`
/// shows it when neither `setupProcess` nor `runAtLoginInitialized` is set,
/// and starts the app when it closes.
///
/// Everything it decides is in `SetupFlow.swift` and tested there, because
/// this window is shown exactly once per installation and then never again —
/// there is no second occasion on which anybody would notice it had gone
/// wrong. What it writes outlives it by the whole life of the install.

/// 700 × 440. Wide enough for a four-preset menu bar preview at its real
/// size, which is what sets it: the previews are drawn at menu bar scale so
/// that what somebody picks is what they get, and the widest of them is a
/// little over 300pt.
private let setupSize = CGSize(width: 700, height: 440)

/// The strip along the bottom holding Previous and Next.
private let footerHeight: CGFloat = 60

// MARK: - The window

final class SetupWindow: NSWindow, NSWindowDelegate {

    /// Called when the window closes, however it closes — the Finish button
    /// and the red dot both mean "I am done with this".
    var finishHandler: () -> Void = {}

    /// For whoever is holding the window, to let go of it.
    var onClose: (() -> Void)?

    private let chrome = SetupChrome()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: setupSize),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: true)

        contentView = chrome
        chrome.onFinish = { [weak self] in self?.hide() }

        title = localized("Roost Setup")
        titlebarAppearsTransparent = true
        animationBehavior = .default
        // The window is closed by the Finish button and shown once, but
        // `close()` on a released window is a crash and this one is held by
        // `Startup` across the close.
        isReleasedWhenClosed = false
        delegate = self

        positionCentre()
        setIsVisible(false)
    }

    func show() {
        setIsVisible(true)
        // Roost has no Dock icon, so without activating it the window opens
        // behind whatever the user was doing and the first thing they see of
        // the app is nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func hide() { close() }

    func windowWillClose(_ notification: Notification) {
        finishHandler()
        // Deferred: the holder's release runs while AppKit is still inside
        // this close, and letting go of the window from inside its own
        // delegate callback is how that becomes a use-after-free.
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }

    /// Centred horizontally, and higher than centre vertically.
    ///
    /// Above the middle because a first-run window that opens dead centre
    /// sits over whatever the person was reading. `NSWindow.center()` puts it
    /// at a third from the top, which is close, but it measures against the
    /// visible frame and this has to clear the menu bar Roost is about to
    /// start drawing into.
    private func positionCentre() {
        guard let screen = NSScreen.main else { return center() }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - setupSize.width / 2,
                               y: visible.midY - setupSize.height / 2 + visible.height * 0.12))
    }
}

// MARK: - The frame around the pages

/// The content area, the hairline and the two buttons.
///
/// It owns a `SetupFlow` and renders whatever page the flow says it is on.
/// The version this replaces kept no index at all: it read the first subview
/// of the content area and searched the page array for it by identity to work
/// out where it was. That is a question the flow can answer, asked of a
/// structure that can answer it wrongly.
private final class SetupChrome: NSView {

    var onFinish: () -> Void = {}

    private var flow = SetupFlow()
    private let content = NSView()
    private let previous = NSButton()
    private let next = NSButton()

    init() {
        super.init(frame: NSRect(origin: .zero, size: setupSize))

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let footer = makeFooter()
        addSubview(footer)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight)
        ])

        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A hairline between the pages and the buttons.
    ///
    /// Drawn rather than a view: it is one line, and a 1pt `NSBox` on a
    /// Retina display is two device pixels of grey where one is wanted.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: footerHeight))
        line.line(to: NSPoint(x: bounds.width, y: footerHeight))
        line.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        line.stroke()
    }

    private func makeFooter() -> NSView {
        for (button, action) in [(previous, #selector(goBack)), (next, #selector(goNext))] {
            button.bezelStyle = .regularSquare
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        previous.title = localized("Previous")
        previous.toolTip = localized("Previous page")

        let row = NSStackView(views: [previous, next])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        // The buttons sit centred rather than in the trailing corner, which
        // is where a macOS sheet would put them. This is not a sheet: it is a
        // five-page window with a Previous, and centring the pair keeps the
        // two of them together as one control rather than reading as a
        // primary action with something stranded beside it.
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    // MARK: Navigation

    @objc private func goBack() {
        flow.goBack()
        render()
    }

    @objc private func goNext() {
        if case .finish = flow.advance() {
            onFinish()
            return
        }
        render()
    }

    /// Put the current page on screen and make the buttons agree with it.
    ///
    /// Both button states are recomputed from the flow every time rather than
    /// adjusted on the way past. The version this replaces set them in an
    /// `if` / `else if` / `else` on the index, and the branch that restored
    /// the Next title was the middle one — so a window with two pages would
    /// have shown Finish and then never changed it back.
    private func render() {
        previous.isEnabled = flow.canGoBack
        next.title = flow.nextTitle
        next.toolTip = flow.nextTooltip

        content.subviews.forEach { $0.removeFromSuperview() }
        let page = SetupPageView(flow.page)
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
}

// MARK: - A page

/// One page: a heading, and whatever that page is for.
///
/// One view for all five rather than five near-identical `NSStackView`
/// subclasses, each repeating the same heading, the same grid and the same
/// hand-set row heights. The pages differ in their content and nothing else,
/// so the content is the only thing a page supplies.
final class SetupPageView: NSView {

    init(_ page: SetupPage) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: setupSize.width,
                                 height: setupSize.height - footerHeight))

        let heading = SetupText.heading(SetupPageView.title(of: page))
        let body = SetupPageView.body(of: page)

        let column = NSStackView(views: [heading, body])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // Pinned near the top rather than centred vertically. The five pages
        // are different heights -- an icon and a line, against six radio
        // buttons -- and centring each one moves the heading every time the
        // page changes, so the first thing the eye has to do on each page is
        // find the title again.
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func title(of page: SetupPage) -> String {
        switch page {
        case .welcome:   return localized("Welcome to Roost")
        case .preset:    return localized("Select preset")
        case .windowControl: return localized("Window control")
        case .loginItem: return localized("Start at login")
        case .updates:   return localized("Check for updates")
        case .done:      return localized("You're all set")
        }
    }

    private static func body(of page: SetupPage) -> NSView {
        switch page {
        case .welcome:   return WelcomePage()
        case .preset:    return PresetPage()
        case .windowControl: return WindowControlPage()
        case .loginItem: return LoginItemPage()
        case .updates:   return UpdatesPage()
        case .done:      return DonePage()
        }
    }
}

/// Builds one setup page on its own, for `--render setup:<n>`.
///
/// The five pages cannot be looked at any other way once somebody has
/// finished setup, and the window is shown once per installation. Rendering
/// them is the only check the drawing gets; `Tools/setup-test.swift` covers
/// everything that is not drawing.
internal func makeSetupPage(_ index: Int) -> NSView? {
    guard let page = SetupPage(rawValue: index) else { return nil }
    return SetupPageView(page)
}

/// The whole window, chrome included, for `--render setup:window`.
internal func makeSetupChrome() -> NSView { SetupChrome() }

// MARK: - Text

/// The two kinds of text this window has.
///
/// Both are given an explicit wrapping width. The paragraph on the last page
/// is three lines, and a multi-line `NSTextField` with no width to wrap
/// against picks one from its intrinsic content size — which, for a label
/// built from a zero frame, came out as a 130pt column down the middle of a
/// 700pt window. Any new page with more than one line of text inherits that
/// trap, so neither of these leaves the width unset.
private enum SetupText {

    static let wrapWidth = setupSize.width - 80

    static func heading(_ text: String) -> NSTextField {
        let label = label(text, size: 20, weight: .semibold)
        label.alignment = .center
        return label
    }

    static func body(_ text: String, alignment: NSTextAlignment = .center) -> NSTextField {
        let label = label(text, size: 13, weight: .regular)
        label.alignment = alignment
        return label
    }

    static func caption(_ text: String) -> NSTextField {
        let label = label(text, size: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .natural
        return label
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        // A wrapping label. `labelWithString` is single-line whatever width
        // it is given -- the wrap width below was being honoured as a clip,
        // which cut the welcome sentence off at "This short setu".
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.toolTip = text
        field.translatesAutoresizingMaskIntoConstraints = false
        field.preferredMaxLayoutWidth = wrapWidth
        field.widthAnchor.constraint(lessThanOrEqualToConstant: wrapWidth).isActive = true
        return field
    }
}

/// A radio button bound to a closure, so a page does not need a selector per
/// option and an `identifier` to carry the value through it.
private final class SetupChoice: NSButton {
    private let chosen: () -> Void

    init(_ title: String, selected: Bool, chosen: @escaping () -> Void) {
        self.chosen = chosen
        super.init(frame: .zero)
        setButtonType(.radio)
        self.title = title
        self.state = selected ? .on : .off
        self.isBordered = false
        self.target = self
        self.action = #selector(press)
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func press() { chosen() }
}

// MARK: - Welcome

private final class WelcomePage: NSView {
    init() {
        super.init(frame: .zero)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let message = SetupText.body(localized("welcome_message"))

        let column = NSStackView(views: [icon, message])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 120),
            icon.heightAnchor.constraint(equalToConstant: 120),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Presets

/// The page that decides what the menu bar looks like.
///
/// Each row is a name and a picture of the menu bar that choosing it
/// produces, drawn by `MenuBarWidget` at the size it will really be — not an
/// illustration of it. The pictures are the point of the page: the names mean
/// nothing to somebody who has not used the app yet.
private final class PresetPage: NSView {

    private var rows: [(radio: NSButton, preview: NSView)] = []

    init() {
        super.init(frame: .zero)

        let caption = SetupText.caption(localized("select_preset_message"))

        let column = NSStackView(views: [caption])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false

        for (index, preset) in SetupPreset.all.enumerated() {
            column.addArrangedSubview(makeRow(index, preset))
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor)
        ])

        select(SetupPreset.defaultIndex, apply: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeRow(_ index: Int, _ preset: SetupPreset) -> NSView {
        let radio = SetupChoice(localized(preset.name), selected: false) { [weak self] in
            self?.select(index)
        }
        radio.font = .systemFont(ofSize: 13, weight: .medium)
        radio.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let preview = makePreview(preset)
        // The picture is the part worth clicking, and it is far the larger
        // target. Clicking it selects the row, same as the radio.
        preview.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(previewClicked)))

        rows.append((radio, preview))

        let row = NSStackView(views: [radio, preview, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    /// A strip of menu bar holding this preset's shapes at their real size.
    private func makePreview(_ preset: SetupPreset) -> NSView {
        let images = preset.items.compactMap {
            // `preview` returns nil for a shape the sample reading cannot
            // fill, which is how every preset's Network entry came to be
            // drawn as nothing: the sample had a `pair` and no `rates`, so
            // `canDraw` refused the rate shapes and they measured zero wide.
            // Anything added to MenuBarReading needs a sample here too.
            MenuBarWidget.preview($0.style, label: $0.module, load: 0.38)
        }

        let strip = NSStackView(views: images.map { image in
            let view = NSImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: image.size.width).isActive = true
            view.heightAnchor.constraint(equalToConstant: image.size.height).isActive = true
            return view
        })
        strip.orientation = .horizontal
        strip.spacing = MenuBarMetrics.padding * 2
        strip.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        strip.translatesAutoresizingMaskIntoConstraints = false

        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        plate.layer?.cornerCurve = .continuous
        plate.layer?.masksToBounds = true
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.setContentHuggingPriority(.required, for: .horizontal)
        plate.addSubview(strip)

        NSLayoutConstraint.activate([
            plate.heightAnchor.constraint(equalToConstant: MenuBarMetrics.height + 10),
            strip.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            strip.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
        ])
        return plate
    }

    @objc private func previewClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let index = rows.firstIndex(where: { $0.preview === view }) else { return }
        select(index)
    }

    /// `apply` is false for the initial selection: showing the page must not
    /// rewrite the preferences of somebody who opened it and pressed Next.
    private func select(_ index: Int, apply: Bool = true) {
        guard SetupPreset.all.indices.contains(index) else { return }

        for (position, row) in rows.enumerated() {
            let selected = position == index
            row.radio.state = selected ? .on : .off
            row.preview.layer?.backgroundColor = (selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                : NSColor(white: 0.5, alpha: 0.14)).cgColor
            row.preview.layer?.borderWidth = selected ? 1.5 : 0
            row.preview.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }

        guard apply else { return }
        // Through `Preferences`, which posts. The store this replaced wrote
        // silently, which is why a preset could set a shape that nothing
        // acted on until the next launch.
        for write in SetupPreset.all[index].writes() {
            switch write {
            case .flag(let key, let value): Preferences.shared.set(key, value)
            case .text(let key, let value): Preferences.shared.set(key, value)
            }
        }
    }
}

// MARK: - Start at login

/// What the launcher half needs, asked for while there is time to explain it.
///
/// Every shortcut that moves a window -- minimising, restoring, snapping --
/// depends on Accessibility, and without this page the first a new user
/// heard of it was a notice when a shortcut did nothing. The status follows
/// the grant live, because the grant happens in System Settings, not here.
private final class WindowControlPage: NSView {

    private let status = NSTextField(labelWithString: "")
    private let allow = NSButton()
    private var timer: Timer?

    init() {
        super.init(frame: .zero)

        let message = SetupText.body(localized("window_control_message"))

        let grid = NSGridView(views: [
            ("⌃Space", localized("Search and switch apps")),
            ("⌃Tab", localized("Cycle the apps you mark")),
            ("⌃⌥← →", localized("Snap a window to half the screen")),
            ("⌃`", localized("Minimise and bring back"))
        ].map { keys, what -> [NSView] in
            let key = NSTextField(labelWithString: keys)
            key.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            key.alignment = .right
            let text = NSTextField(labelWithString: what)
            text.font = .systemFont(ofSize: 12)
            text.textColor = .secondaryLabelColor
            return [key, text]
        })
        grid.columnSpacing = 14
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        // Its natural width, so the column centres it rather than stretching
        // it and leaving the keys stranded at the right.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        grid.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 12, weight: .medium)
        allow.title = localized("Allow…")
        allow.bezelStyle = .rounded
        allow.target = self
        allow.action = #selector(grant)
        let row = NSStackView(views: [status, allow])
        row.spacing = 10

        let column = NSStackView(views: [message, grid, row])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 22
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Once a second, only while this page is on screen.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let trusted = WindowControl.isTrusted
        status.stringValue = trusted ? "✓ " + localized("Allowed") : localized("Not allowed yet")
        status.textColor = trusted ? .systemGreen : .secondaryLabelColor
        allow.isHidden = trusted
    }

    @objc private func grant() { WindowControl.grantFromSettings() }
}

private final class LoginItemPage: NSView {
    init() {
        super.init(frame: .zero)

        let on = SetupChoice(localized("Start the application automatically when starting your Mac"),
                             selected: LoginItem.isEnabled) { [weak self] in self?.set(true) }
        let off = SetupChoice(localized("Do not start the application automatically when starting your Mac"),
                              selected: !LoginItem.isEnabled) { [weak self] in self?.set(false) }
        choices = [on, off]

        let column = NSStackView(views: choices)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var choices: [NSButton] = []

    private func set(_ enabled: Bool) {
        LoginItem.isEnabled = enabled
        choices.first?.state = enabled ? .on : .off
        choices.last?.state = enabled ? .off : .on
        // The marker that first-run has happened, and the key the app reads
        // to decide whether to show this window again. Written on a choice
        // rather than on the page appearing, so closing the window without
        // touching anything leaves the default alone.
        if !Preferences.shared.exists("runAtLoginInitialized") {
            Preferences.shared.set("runAtLoginInitialized", true)
        }
    }
}

// MARK: - Updates

private final class UpdatesPage: NSView {

    /// Offered in this order, with a gap after the two that act immediately
    /// and before Never. The gaps are the only thing separating "check when
    /// you feel like it" from "do not check", which is a choice worth not
    /// making by accident.
    private static let groups: [[UpdateInterval]] = [
        [.silent, .atStart],
        [.oncePerDay, .oncePerWeek, .oncePerMonth],
        [.never]
    ]

    private static func caption(for interval: UpdateInterval) -> String {
        switch interval {
        case .silent:       return localized("Do everything silently in the background (recommended)")
        case .atStart:      return localized("Check for a new version on startup")
        case .oncePerDay:   return localized("Check for a new version every day (once a day)")
        case .oncePerWeek:  return localized("Check for a new version every week (once a week)")
        case .oncePerMonth: return localized("Check for a new version every month (once a month)")
        case .never:        return localized("Never check for updates (not recommended)")
        }
    }

    private var choices: [(interval: UpdateInterval, button: NSButton)] = []

    init() {
        super.init(frame: .zero)

        let stored = Preferences.shared.string("update-interval", default: UpdateInterval.defaultStored)
        let current = UpdateInterval.interval(from: stored) ?? .never

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        for (index, group) in UpdatesPage.groups.enumerated() {
            if index > 0 {
                let gap = NSView()
                gap.translatesAutoresizingMaskIntoConstraints = false
                gap.heightAnchor.constraint(equalToConstant: 8).isActive = true
                column.addArrangedSubview(gap)
            }
            for interval in group {
                let button = SetupChoice(UpdatesPage.caption(for: interval),
                                         selected: interval == current) { [weak self] in
                    self?.select(interval)
                }
                choices.append((interval, button))
                column.addArrangedSubview(button)
            }
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func select(_ interval: UpdateInterval) {
        for choice in choices { choice.button.state = choice.interval == interval ? .on : .off }
        // The raw value, which is the string already on disk for anybody
        // upgrading -- "Once per day", not a case name.
        Preferences.shared.set("update-interval", interval.rawValue)
    }
}

// MARK: - Done

private final class DonePage: NSView {
    init() {
        super.init(frame: .zero)

        // Not "You are all set." again: the page's title says it now.
        let message = SetupText.body(localized("finish_setup_body"))

        let links = NSStackView()
        links.orientation = .horizontal
        links.spacing = 12
        links.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)

        // The upstream hosted service, Sponsors, PayPal, Ko-fi and Patreon
        // buttons are gone: every one of them paid the original author rather
        // than this fork, and the first advertised a service this fork cannot
        // serve. Set AppLinks.donationURL to put a button of your own back.
        if let repository = AppLinks.repositoryURL {
            // A symbol for "source code", not GitHub's mark: the mark is
            // GitHub's trademark and arrived as an asset with the import.
            links.addArrangedSubview(SetupLink(name: "GitHub",
                                               image: "chevron.left.forwardslash.chevron.right") {
                NSWorkspace.shared.open(repository)
            })
        }
        if let donation = AppLinks.donationURL {
            links.addArrangedSubview(SetupLink(name: localized("Donate"), image: "AppIcon") {
                NSWorkspace.shared.open(donation)
            })
        }

        let column = NSStackView(views: [message, links])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An icon that opens a link.
private final class SetupLink: NSButton {
    private let open: () -> Void

    init(name: String, image: String, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))

        // Named under the icon: two unlabelled icons on the last page did not
        // say that one is the source code and the other the support page.
        title = name
        font = .systemFont(ofSize: 10)
        imagePosition = .imageAbove
        toolTip = name
        setAccessibilityLabel(name)
        // An asset, or failing that a system symbol of that name -- never a
        // force unwrap: a missing image should cost a blank button, not a
        // crash on the last page of first run.
        let picture = NSImage(named: image)?.copy() as? NSImage
            ?? NSImage(systemSymbolName: image, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        // One size for both, so their names line up underneath.
        picture?.size = NSSize(width: 24, height: 24)
        self.image = picture
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        alphaValue = 0.9
        target = self
        action = #selector(press)
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = 1
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 0.9
        NSCursor.arrow.set()
    }

    @objc private func press() { open() }
}
