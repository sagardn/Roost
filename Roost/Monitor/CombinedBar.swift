import AppKit

/// One module's presence inside a shared menu bar item.
///
/// A module in combined mode does not own an item. It hands over a view, says
/// how wide that view needs to be, and is told when it has been pressed.
/// Everything else -- the item itself, the order, the gaps, the separators,
/// and which reading a press landed on -- belongs to `CombinedBar`.
///
/// Deliberately not tied to `RoostModule`. The modules Kit still owns draw
/// through views Kit keeps sized; the ones Roost owns draw through
/// `MenuBarWidget`. Both are segments, and the bar cannot tell them apart,
/// which is what lets a module move from one to the other without combined
/// mode noticing.
protocol MenuBarSegment: AnyObject {

    /// The module's name. Also the key the layout identifies it by.
    var name: String { get }

    /// The view that draws the reading. The module owns it; the bar only
    /// positions it.
    var view: NSView { get }

    /// How wide the reading is now -- asked for on every pass rather than
    /// stored, because a module's width changes under it: a network rate
    /// going from "0 KB/s" to "12.4 MB/s" needs more room than it had.
    var width: CGFloat { get }

    /// False when there is nothing to draw, which for the Kit modules means
    /// every one of their widgets is switched off. Such a module is left out
    /// of the row entirely rather than contributing an invisible gap that
    /// still swallows clicks.
    var isVisible: Bool { get }

    /// Called when the row changes width, so the bar can reflow at the
    /// moment it happens instead of on the next tick. Set by the host.
    var onResize: (() -> Void)? { get set }

    /// The shared tick. A Roost module re-reads here; a Kit module is driven
    /// by its own readers and does nothing.
    func refresh()

    /// Pressed.
    ///
    /// `anchor` is this segment's own rectangle in screen coordinates -- not
    /// the whole row's -- so a popup opens under the reading that was
    /// clicked rather than under the middle of everything. `offsetX` is where
    /// inside the segment the press landed, which matters only to a module
    /// drawing several readings side by side.
    func activate(anchor: NSRect, offsetX: CGFloat)

    /// Taken out of the row. The view is going back to the module.
    func detach()
}

extension MenuBarSegment {
    var isVisible: Bool { true }
    func refresh() {}
    func detach() {}
}

/// A reading Roost draws itself, in `MenuBarWidget`.
///
/// The segment a Roost module gets for nothing: a name, a reading and a
/// popup are already what `PopupContent` is, so there is no second interface
/// for a module to implement in order to be in the menu bar. Used in both
/// modes -- one of these in its own item, or several of them in a row -- so
/// the two modes draw the identical pixels.
final class WidgetSegment: MenuBarSegment {

    let content: PopupContent
    private let widget = MenuBarWidget()

    /// Built on first press and kept afterwards: the popup holds the chart
    /// history, and reopening it should not start the charts again.
    private var popup: ReadingPopup?

    /// Watches `<Module>_widget`, so ticking a shape in Settings changes the
    /// menu bar as it is ticked.
    private var styleObserver: Any?

    var onResize: (() -> Void)?

    var name: String { content.title }
    var view: NSView { widget }
    var width: CGFloat { widget.intrinsicContentSize.width }

    /// Nothing to draw -- every shape switched off, which is a legitimate
    /// choice. The row leaves the module out rather than keeping a
    /// zero-width slot that still takes presses meant for its neighbour.
    ///
    /// Asked of the width rather than the style list, because a module whose
    /// reading is not one of the six -- network's pair of rates -- draws
    /// regardless of what is ticked.
    var isVisible: Bool { widget.intrinsicContentSize.width > 0 }

    init(content: PopupContent) {
        self.content = content
        widget.styles = MenuBarStyles.stored(for: content.title,
                                             default: content.defaultMenuBarStyles)
        widget.frame = NSRect(x: 0, y: 0,
                              width: widget.intrinsicContentSize.width,
                              height: CombinedBar.height)
        refresh()

        styleObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  note.object as? String == MenuBarStyles.key(self.content.title) else { return }
            self.widget.styles = MenuBarStyles.stored(for: self.content.title,
                                                      default: self.content.defaultMenuBarStyles)
            self.onResize?()
        }
    }

    deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    /// One sampling step. Cheap by contract -- see `menuBarContent()`.
    func refresh() {
        guard let reading = content.menuBarContent() else { return }
        let before = widget.intrinsicContentSize.width
        widget.content = reading
        if abs(widget.intrinsicContentSize.width - before) > 0.5 { onResize?() }
    }

    func activate(anchor: NSRect, offsetX: CGFloat) {
        if popup == nil { popup = ReadingPopup(content: content) }
        popup?.toggle(below: anchor)
    }

    /// Closed but kept. The reading may be back in the menu bar in a moment
    /// -- that is what changing modes is -- and its charts should still be
    /// there when it is.
    func detach() { popup?.hide() }
}

/// Every module's reading in one menu bar item.
///
/// Replaces `CombinedView`, which composed Kit's widget views out of the
/// global module array and so could not survive a module leaving that array.
/// This holds segments, which any module can supply, and keeps the arithmetic
/// in `CombinedLayout` where it is testable. The three things that were
/// broken are fixed by construction: the switch takes effect without a
/// restart, the spacing setting is read in the form Settings writes it, and
/// turning on separators reflows the row instead of waiting for the next
/// widget resize.
final class CombinedBar {

    /// The height every shape is drawn for: 22, fixed.
    ///
    /// It was read from `mainMenu?.menuBarHeight`, falling back to 22. Roost
    /// had no main menu, so that was nil and 22 is what every shape was
    /// designed, measured and shipped at. The day a main menu was added it
    /// answered the real bar's height -- taller on a Mac with a notch -- and
    /// every item drew its figures below the space the status item gives
    /// them: the names showed and the numbers were cut off.
    static var height: CGFloat { 22 }

    private var item: NSStatusItem?
    private let row = CombinedRow()
    private var segments: [MenuBarSegment] = []
    private var layout = CombinedLayout(of: [])

    /// The details popup, built on first use and kept: it holds the modules'
    /// own tiles, and rebuilding it would throw away their charts.
    private var details: ReadingPopup?
    private let detailsContent = CombinedDetails()

    private var relayoutScheduled = false

    private var prefs: Preferences { .shared }

    /// What the details popup stacks. Set by whoever owns the registry, so
    /// the bar does not have to know where modules come from.
    var tiles: (() -> [(name: String, view: NSView)])? {
        get { detailsContent.tiles }
        set { detailsContent.tiles = newValue }
    }

    var isShowing: Bool { item != nil }

    /// The row as it currently stands.
    var slots: [CombinedLayout.Slot] { layout.slots }

    /// The tiles the details popup is showing.
    var detailTiles: [String] { detailsContent.showing }

    /// The window the row is drawn in, for anchoring a popup from outside.
    var window: NSWindow? { item?.button?.window }

    // MARK: - The item

    func show() {
        guard item == nil else { return }

        // Length zero to begin with: the row is measured in `relayout`, and
        // an item that appears at its default width and then shrinks is a
        // visible jump every launch.
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.button?.image = NSImage()
        item.button?.toolTip = localized("Combined modules")
        item.button?.target = self
        item.button?.action = #selector(handlePress)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.addSubview(row)
        self.item = item

        // Deferred, as it was: setting the autosave name while the item is
        // being installed makes macOS restore the saved position on top of
        // the one it is still placing.
        DispatchQueue.main.async { item.autosaveName = "CombinedModules" }

        relayout()
    }

    func hide() {
        details?.hide()
        details = nil
        for segment in segments {
            segment.onResize = nil
            segment.view.removeFromSuperview()
            segment.detach()
        }
        segments = []
        layout = CombinedLayout(of: [])
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    // MARK: - Contents

    /// The modules in the row, in display order.
    ///
    /// Replacing the list is how the row is rebuilt. Segments that are no
    /// longer in it are detached and their views handed back, so a module
    /// switched off while combined mode is on leaves nothing behind.
    func setSegments(_ wanted: [MenuBarSegment]) {
        for old in segments where !wanted.contains(where: { $0 === old }) {
            old.onResize = nil
            old.view.removeFromSuperview()
            old.detach()
        }
        segments = wanted
        for segment in segments {
            segment.onResize = { [weak self] in self?.relayoutSoon() }
        }
        relayout()
    }

    /// One sampling step for every segment, then a reflow if any of them
    /// changed width. The poll is the backstop: a module that resizes without
    /// saying so still gets a correct row within a second.
    func tick() {
        guard item != nil else { return }
        segments.forEach { $0.refresh() }
        if measurements() != layout.slots.map({ .init($0.name, $0.width) }) {
            relayout()
        }
    }

    private func measurements() -> [CombinedLayout.Measurement] {
        segments.filter { $0.isVisible }.map { .init($0.name, $0.width) }
    }

    /// Coalesced, because a module can report a resize from inside the pass
    /// that resized it. One more pass on the next turn of the run loop, never
    /// a recursive one.
    private func relayoutSoon() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.relayout()
        }
    }

    func relayout() {
        guard let item else { return }

        let visible = segments.filter { $0.isVisible }

        // A segment that says it has something to draw but reports no width
        // has not been measured yet, and is given a provisional slot so that
        // it can draw once -- the draw is what tells us how wide it really
        // is.
        //
        // This is not belt and braces. The framework the Kit modules are
        // still built on sizes its menu bar view from its widgets' own
        // frames, and after the combined switch is moved at runtime that
        // accounting comes back zero and never corrects: measured, every Kit
        // module reported width 0 for as long as the app ran, so the row held
        // nothing but the one module Roost draws itself. Dropping a
        // zero-width segment -- which is right, since a slot nobody can see
        // still swallows presses -- turned that into the module vanishing.
        // Letting it draw closes the loop through the screen instead of
        // through the framework's bookkeeping, which is the part that is
        // wrong.
        let provisional: CGFloat = 24
        layout = CombinedLayout(
            of: visible.map { .init($0.name, $0.width > 0 ? $0.width : provisional) },
            spacing: CombinedLayout.spacing(named: prefs.combinedSpacing),
            separators: prefs.combinedSeparator)

        // Anything not in the row comes out of it, so a module with every
        // widget off cannot take a press meant for its neighbour.
        for segment in segments where !visible.contains(where: { $0 === segment }) {
            segment.view.removeFromSuperview()
        }

        let height = Self.height
        for (slot, segment) in zip(layout.slots, visible) {
            if segment.view.superview !== row { row.addSubview(segment.view) }
            segment.view.setFrameOrigin(NSPoint(x: slot.x, y: 0))
            // The width as well as the height: a view left at zero width
            // never draws, and a view that never draws never tells anyone how
            // wide it wanted to be.
            let wanted = NSSize(width: slot.width, height: height)
            if abs(segment.view.frame.width - wanted.width) > 0.5
                || abs(segment.view.frame.height - wanted.height) > 0.5 {
                segment.view.setFrameSize(wanted)
            }
        }

        row.rules = layout.rules.map { $0.x }
        row.setFrameOrigin(.zero)
        row.setFrameSize(NSSize(width: layout.width, height: height))
        if abs(item.length - layout.width) > 0.5 { item.length = layout.width }
    }

    // MARK: - Pressing

    @objc private func handlePress() {
        guard let window = item?.button?.window else { return }

        // "Combined details" on: the whole row is one button onto one popup
        // holding every module's tile. Off: the row is as many buttons as it
        // has readings, and the press goes to the one under the pointer.
        if prefs.combinedPopup {
            toggleDetails(below: window.frame)
            return
        }

        press(atX: row.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation),
                               from: nil).x)
    }

    /// Open one module's popup by name, as a press on its reading would.
    @discardableResult
    func press(on name: String) -> Bool {
        guard let slot = layout.slots.first(where: { $0.name == name }) else { return false }
        return press(atX: slot.x) != nil
    }

    /// Open or close the details popup, as a press does while "Combined
    /// details" is on. Returns whether it is now on screen.
    @discardableResult
    func toggleDetails() -> Bool {
        guard let window = item?.button?.window else { return false }
        toggleDetails(below: window.frame)
        return details?.isVisible ?? false
    }

    /// The press, by where in the row it landed.
    ///
    /// Split from `handlePress`, which does nothing but turn a mouse location
    /// into a position in the row. Everything that can be wrong is on this
    /// side of the split, and this side can be driven without a mouse --
    /// `--menu-bar press:<x>` does, because posting a click into a status
    /// item needs Accessibility and a misrouted press looks exactly like a
    /// routed one in a screenshot.
    @discardableResult
    func press(atX x: CGFloat) -> String? {
        guard let window = item?.button?.window,
              let slot = layout.slot(atX: x),
              let segment = segments.first(where: { $0.name == slot.name }) else { return nil }

        let anchor = NSRect(x: window.frame.minX + slot.x, y: window.frame.minY,
                            width: slot.width, height: window.frame.height)
        segment.activate(anchor: anchor, offsetX: x - slot.x)
        return segment.name
    }

    private func toggleDetails(below anchor: NSRect) {
        if details == nil { details = ReadingPopup(content: detailsContent) }
        details?.toggle(below: anchor)
    }
}

// MARK: - The row

/// The view inside the combined item.
///
/// Hosts the segments' own views and draws the separators between them. The
/// separators are drawn rather than built as subviews: there is nothing to
/// click on a hairline, and a view per gap was a view to create, place and
/// tear down on every reflow.
private final class CombinedRow: NSView {

    var rules: [CGFloat] = [] {
        didSet {
            guard rules != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rules.isEmpty else { return }
        ink.setFill()
        for x in rules {
            NSRect(x: x, y: 3,
                   width: CombinedLayout.ruleWidth,
                   height: bounds.height - 6).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Resolved per draw, like `MenuBarWidget`'s: the bar flips with the
    /// wallpaper behind it, not only with the system appearance.
    private var ink: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white : .black
    }
}

// MARK: - The details popup

/// What the combined item opens: one tile per module, stacked.
///
/// The tiles are the modules' own, so this knows nothing about processors or
/// networks -- it arranges views and hides the ones whose module is off.
/// Built once and kept: a tile holds a chart, and rebuilding the stack on
/// every open would throw the history away.
final class CombinedDetails: PopupContent {

    let title = localized("Combined modules")

    var tiles: (() -> [(name: String, view: NSView)])?

    private let stack = NSStackView()
    private var placed: [String: NSView] = [:]
    private let note = EmptyNote()

    /// Which tiles are on screen, for checking the popup from outside.
    var showing: [String] {
        placed.filter { !$0.value.isHidden }.keys.sorted()
    }

    func makeView() -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth).isActive = true
        fill()
        return stack
    }

    func willShow() { fill() }

    func refresh() {}

    /// Adds any tile that has appeared since the last open and hides the ones
    /// whose module has gone.
    ///
    /// A tile is hidden rather than removed: the module still owns it, and
    /// taking it out of the stack would drop the constraints pinning it --
    /// which is also why each tile is added exactly once, however many times
    /// the popup is opened.
    private func fill() {
        let wanted = tiles?() ?? []
        let names = Set(wanted.map { $0.name })

        for tile in wanted where placed[tile.name] == nil {
            tile.view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(tile.view)
            tile.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            placed[tile.name] = tile.view
        }
        for (name, view) in placed {
            view.isHidden = !names.contains(name)
        }

        if note.superview == nil { stack.addArrangedSubview(note) }
        note.isHidden = !wanted.isEmpty
    }
}

/// Shown when combined details is on and no module has a tile to show.
///
/// Better than an empty panel the size of a header: a popup that opens blank
/// reads as broken rather than as nothing to report.
private final class EmptyNote: NSView {

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString:
            localized("No module has anything to show here yet."))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
