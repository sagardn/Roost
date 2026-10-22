import AppKit

/// A Spotlight-style launcher: search field on top, results below.
///
/// Deliberately not a text field embedded in the NSMenu. NSMenu runs its own
/// event-tracking loop and does not reliably route keystrokes to a hosted
/// view, so a search box inside the menu ends up half-working. A panel is
/// what Spotlight itself is, and it gets real keyboard handling.
/// A table whose single column stays as wide as the table itself.
///
/// NSTableColumn keeps its default 100pt width unless something actually sizes
/// it. `resizingMask = .autoresizingMask` does not, and neither does any of
/// the three columnAutoresizingStyle values -- all four were measured on a
/// programmatically built single-column table and all four left the column at
/// 100pt. Every row view was therefore 100pt wide no matter how wide the
/// table was, so anything laid out against a row's trailing edge sat in the
/// wrong place and long names were truncated at any window size.
class SingleColumnTableView: NSTableView {
    /// Taken off the column width. The .inset style already insets each row
    /// for its selection capsule; this keeps the two from fighting.
    var columnInset: CGFloat = 0

    override func layout() {
        super.layout()
        guard needsColumnResize else { return }
        // Not here: setting a column's width calls -[NSTableView tile], which
        // calls setFrameSize:, which lays out again. Doing that from inside a
        // layout pass re-enters tile and AppKit throws -- it crashed on the
        // first draw of the window, in viewWillDraw. One turn later the pass
        // is over and the assignment is just an ordinary resize.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsColumnResize,
                  let column = self.tableColumns.first else { return }
            column.width = self.wantedColumnWidth
        }
    }

    /// Measured from the clip view, never from the table's own bounds: the
    /// table resizes itself to fit its columns, so `bounds.width - inset` is
    /// circular -- it fed back and the column oscillated well past the visible
    /// width (329 -> 353 -> 365pt inside a 305pt panel), pushing the ⌃⇥ badge
    /// and the options chevron off the right-hand edge.
    private var wantedColumnWidth: CGFloat {
        let available = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        return max(1, available - columnInset)
    }

    private var needsColumnResize: Bool {
        guard let column = tableColumns.first else { return false }
        return abs(column.width - wantedColumnWidth) > 0.5
    }
}

/// A table that acts on the very first click.
///
/// By default AppKit spends the first click in an inactive window on
/// activating it, so picking a row takes two clicks -- which is exactly what
/// happens when the panel is opened by the trackpad gesture rather than the
/// hotkey, since the app is not frontmost at that moment.
private final class ClickThroughTableView: SingleColumnTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SearchPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {

    /// One searchable thing: either a configured entry or a running app.
    struct Row {
        let name: String
        let bundleID: String
        let icon: NSImage?
        let state: AppState
        let score: Int
        var pinned: Bool = false
        /// In the ⌃Tab cycle.
        var marked: Bool = false
        /// A sum, a conversion or an action rather than an app.
        var quick: QuickSearch.Result?
    }

    private let field = NSTextField()
    private let table = ClickThroughTableView()
    /// Held so its width can be set explicitly -- see resize().
    private let column = NSTableColumn(identifier: .init("main"))
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    private var source: () -> [AppEntry] = { [] }
    /// Called with the picked app and the app that was in front before the
    /// panel opened -- see `WindowControl.toggle` for why the second one.
    private var onPick: (AppEntry, String?) -> Void = { _, _ in }

    /// The app in front when the panel was asked for, before the panel took
    /// focus. Nil when that was Roost itself.
    private var activeBeforeShow: String?
    private var onSetListed: ([AppEntry], Bool) -> Void = { _, _ in }
    private var onEditApps: () -> Void = {}
    private var isMarked: (String) -> Bool = { _ in false }
    private var onSetMarked: (AppEntry, Bool) -> Void = { _, _ in }
    /// True while the options menu is running its own event loop, which costs
    /// the panel key status without the user having clicked away.
    private var optionsOpen = false
    /// Watches for a click anywhere outside the app. resignKey covers the
    /// usual case, but it does not fire for every way focus can move, so this
    /// is the backstop that makes "click away and it goes" always true.
    private var outsideClickMonitor: Any?

    /// A trailing "Add an App…" row, shown once the user has typed
    /// something. The results only ever cover what is running or already
    /// listed, so a query that finds nothing would otherwise be a dead end --
    /// and this is also the one place where adding an app is the obvious next
    /// move. Hidden on the empty query, where the list is just recents.
    private var showsAddRow: Bool { !field.stringValue.isEmpty }
    private var addRowIndex: Int { rows.count }

    private let rowHeight: CGFloat = 44
    private let fieldHeight: CGFloat = 52
    private let maxVisibleRows = 8

    // Row layout, also used to measure how wide the panel needs to be.
    private let labelFont = NSFont.systemFont(ofSize: 15)
    private let sidePadding: CGFloat = 18
    private let iconWidth: CGFloat = 26
    private let dotWidth: CGFloat = 12
    private let arrowWidth: CGFloat = 20
    private let badgeWidth: CGFloat = 26
    /// What NSTableView's .inset style takes off a row, both sides together.
    /// Measured from a capture: 10pt a side.
    private let tableInset: CGFloat = 20
    private let minWidth: CGFloat = 300
    private let maxWidth: CGFloat = 620

    // MARK: - Setup

    init(source: @escaping () -> [AppEntry],
         onPick: @escaping (AppEntry, String?) -> Void,
         onSetListed: @escaping ([AppEntry], Bool) -> Void,
         onEditApps: @escaping () -> Void,
         isMarked: @escaping (String) -> Bool,
         onSetMarked: @escaping (AppEntry, Bool) -> Void) {
        self.source = source
        self.onPick = onPick
        self.onSetListed = onSetListed
        self.onEditApps = onEditApps
        self.isMarked = isMarked
        self.onSetMarked = onSetMarked
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: fieldHeight),
                   // NOT .nonactivatingPanel: that tells macOS to keep the
                   // app inactive, so the panel cannot hold key focus and
                   // every keystroke goes to the app underneath instead.
                   styleMask: [.borderless],
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

        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = localized("Search apps…")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        // Pinned rather than left .automatic: this style insets every row by
        // tableInset/2 a side for the rounded selection capsule, and the width
        // calculation below has to know that number. Leaving it automatic means
        // the layout silently depends on whatever AppKit picks.
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        // Right-click anywhere on a row. The menu is built on demand from the
        // row that was clicked, not the one that happens to be selected.
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        table.menu = contextMenu
        column.resizingMask = .autoresizingMask
        table.columnInset = tableInset
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            field.heightAnchor.constraint(equalToConstant: 30),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
    }

    override var canBecomeKey: Bool { true }   // borderless panels refuse by default

    // MARK: - Showing

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activeBeforeShow = front == Bundle.main.bundleIdentifier ? nil : front
        field.stringValue = ""
        reload()
        // .accessory apps have no key window until they activate.
        //
        // activate(ignoringOtherApps:) is deprecated on macOS 14+, where
        // activation became cooperative and the request from a background
        // app can simply be declined. When that happens the panel never
        // becomes key, the field never takes first responder, and every
        // keystroke -- arrows included -- lands in the app underneath.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        position()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)

        // If activation was declined the window is up but not key, so nothing
        // is typed into it. Claim it again once the run loop has settled.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.makeKeyAndOrderFront(nil)
            self.makeFirstResponder(self.field)
        }
        startWatchingForOutsideClicks()
    }

    /// At the pointer by default, the way the menu used to drop wherever the
    /// mouse was; centred if the user prefers.  Either way it is clamped so it
    /// cannot land half off the screen.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                     ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var origin: NSPoint
        if Prefs.openAtPointer {
            // hang it just below and slightly right of the pointer
            origin = NSPoint(x: mouse.x - 40, y: mouse.y - frame.height - 8)
        } else {
            origin = NSPoint(x: visible.midX - frame.width / 2,
                             y: visible.midY + visible.height * 0.12)
        }

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }

    func hide() {
        stopWatchingForOutsideClicks()
        orderOut(nil)
    }

    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil, Prefs.hideOnOutsideClick else { return }
        // A global monitor never sees this app's own clicks, so anything it
        // does receive is by definition outside the panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, !self.optionsOpen else { return }
            // A global monitor is not supposed to see this app's own clicks,
            // but while the app is inactive -- which is how the gesture opens
            // it -- a click landing on the panel can still arrive here and
            // dismiss the panel before the row is picked. Check the point.
            guard !NSMouseInRect(NSEvent.mouseLocation, self.frame, false) else { return }
            self.hide()
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    override func resignKey() {
        super.resignKey()
        // Losing focus normally dismisses it, like Spotlight. When the user
        // has turned that off the panel stays put and only Escape, a pick, or
        // the hotkey closes it.
        if Prefs.hideOnOutsideClick && !optionsOpen { hide() }
    }

    // MARK: - Filtering

    /// Subsequence match, ranked so prefixes and word starts win.  Cheap, and
    /// enough for a list of apps -- "vsc" finds Visual Studio Code.
    ///
    /// Folded before matching. A space typed before or after the name made
    /// the space part of the subsequence, so "safari " found nothing -- easy
    /// to type after a word, and answered with "No app named". And "cafe"
    /// now finds Café the way the clipboard search already did.
    private func score(_ name: String, _ query: String) -> Int? {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let query = fold(query.trimmingCharacters(in: .whitespaces))
        let name = fold(name)
        if query.isEmpty { return 0 }
        let haystack = Array(name)
        let needle = Array(query)

        if name.hasPrefix(query) { return 1000 }
        if name.contains(query) { return 700 }

        var i = 0, points = 0, lastWasBoundary = true
        for character in haystack {
            guard i < needle.count else { break }
            if character == needle[i] {
                points += lastWasBoundary ? 12 : 4
                i += 1
            }
            lastWasBoundary = (character == " " || character == "-")
        }
        return i == needle.count ? points : nil
    }

    /// `keepingSelection` is for reloads the user did not ask for -- after
    /// quitting an app from the options menu, say, where snapping back to the
    /// first row would lose their place.
    private func reload(keepingSelection: Bool = false) {
        let previous = keepingSelection && rows.indices.contains(table.selectedRow)
            ? rows[table.selectedRow].bundleID : nil
        let query = field.stringValue
        var seen = Set<String>()
        var found: [Row] = []

        func add(name: String, bundleID: String, pinned: Bool = false) {
            guard !seen.contains(bundleID) else { return }
            guard let points = score(name, query) else { return }
            seen.insert(bundleID)
            found.append(Row(name: name,
                             bundleID: bundleID,
                             icon: Self.icon(for: bundleID),
                             state: WindowControl.state(of: bundleID),
                             score: points,
                             pinned: pinned,
                             marked: isMarked(bundleID)))
        }

        for entry in source() {
            add(name: entry.name, bundleID: entry.bundleID, pinned: entry.pinned)
        }
        for app in WindowControl.runningRegularApps() {
            if let bundleID = app.bundleIdentifier {
                add(name: app.localizedName ?? bundleID, bundleID: bundleID)
            }
        }

        // Empty query: most recently used first, so the app you just came
        // from is the top hit.  With a query, relevance wins and recency only
        // breaks ties.
        rows = found.sorted { lhs, rhs in
            // Pinned entries sit above everything, before relevance or
            // recency get a say.
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if !query.isEmpty && lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lhsRank = Recents.shared.rank(for: lhs.bundleID)
            let rhsRank = Recents.shared.rank(for: rhs.bundleID)
            if lhsRank != rhsRank { return lhsRank > rhsRank }

            let lhsOff = lhs.state == .notRunning, rhsOff = rhs.state == .notRunning
            if lhsOff != rhsOff { return !lhsOff }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Above every app, but only for a query that is unmistakably a sum,
        // a conversion or an action -- QuickSearch never answers a query
        // that could be the start of an app's name.
        let quick = QuickSearch.results(for: query).enumerated().map { index, result in
            Row(name: result.title, bundleID: "roost.quick.\(index)",
                icon: NSImage(systemSymbolName: result.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 20, weight: .regular)),
                state: .notRunning, score: Int.max, quick: result)
        }
        rows = quick + rows

        table.reloadData()
        let restored = previous.flatMap { id in rows.firstIndex { $0.bundleID == id } }
        if let index = restored ?? (numberOfRows(in: table) > 0 ? 0 : nil) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        resize()
    }

    /// Width follows the longest name on show, rather than a fixed slab that
    /// dwarfs entries like "Finder".
    private func measuredWidth() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let widestName = rows
            .map { ($0.name as NSString).size(withAttributes: attributes).width }
            .max() ?? 0

        // Mirrors SearchRowView's constraints exactly, because guessing is how
        // names end up truncated: the old sum used sidePadding on the right
        // where the arrow actually sits 12 from the edge, and left the scroller
        // out altogether. Two small errors in the same direction were enough to
        // clip "Visual Studio Code" and "Launchpad (Apps)" at the default
        // width. The badge is counted whether or not any row shows one -- a
        // list whose width jumped when an app joined the switcher would be
        // worse than one a few points wider than it strictly needs to be.
        //
        //   18 pad | 26 icon | 10 | 12 dot | 4 | name | 6 | 26 badge | 4 | 20 arrow | 12
        //
        // ...inside a row that the table's .inset style has already narrowed by
        // tableInset. That inset is the part this missed, and it is why
        // "Launchpad (Apps)" and "Visual Studio Code" arrived clipped at the
        // default width: the sum was right about the row and wrong about how
        // much of the panel a row gets.
        let leading = sidePadding + iconWidth + 10 + dotWidth + 4
        let trailing = 6 + badgeWidth + 4 + arrowWidth + 12
        // Always reserved. An overlay scroller floats over the content and
        // costs nothing, but the style is a system setting that can change
        // under a running app, and 17pt of extra panel is a far smaller
        // problem than a clipped name.
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroll.scrollerStyle)
        let content = tableInset + leading + widestName + trailing + scroller

        // never narrower than the search field's own placeholder
        let placeholder = ((field.placeholderString ?? "") as NSString)
            .size(withAttributes: [.font: field.font ?? labelFont]).width
        let fieldNeeds = sidePadding * 2 + placeholder + 24 + scroller

        return min(maxWidth, max(minWidth, ceil(max(content, fieldNeeds))))
    }

    private func resize() {
        let visibleRows = min(numberOfRows(in: table), maxVisibleRows)
        let height = fieldHeight + CGFloat(visibleRows) * rowHeight
        let width = measuredWidth()

        var frame = self.frame
        frame.origin.y += frame.height - height   // grow downwards
        frame.size.height = height
        frame.size.width = width

        if let visible = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + 8)
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8),
                                 visible.maxX - width - 8)
        }
        setFrame(frame, display: true)
    }

    private static var iconCache: [String: NSImage] = [:]
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 26, height: 26)
        iconCache[bundleID] = image
        return image
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count + (showsAddRow ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == addRowIndex && showsAddRow {
            let plus = NSImage(systemSymbolName: "plus.circle",
                               accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            // With nothing matched, the row says so first: a lone "Add an
            // App…" read as a strange result rather than as "no results".
            let title = rows.isEmpty ? localized("No app named “%0” — add one…", field.stringValue)
                                     : localized("Add an App…")
            let view = SearchRowView(name: title,
                                     icon: plus,
                                     mark: "",
                                     font: labelFont,
                                     arrowWidth: arrowWidth)
            view.arrow.isHidden = true      // nothing to open options on yet
            view.isCurrent = (row == table.selectedRow)
            return view
        }
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]

        let mark: String
        switch entry.state {
        case .notRunning: mark = ""
        case .minimized:  mark = "\u{25CB}"
        default:          mark = "\u{25CF}"
        }

        let view = SearchRowView(name: entry.name,
                                 icon: entry.icon,
                                 mark: mark,
                                 font: labelFont,
                                 arrowWidth: arrowWidth,
                                 marked: entry.marked)
        view.isCurrent = (row == table.selectedRow)
        view.arrow.target = self
        view.arrow.action = #selector(arrowClicked(_:))
        view.arrow.isHidden = entry.quick != nil   // no options for a sum
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in 0..<numberOfRows(in: table) {
            let view = table.view(atColumn: 0, row: index, makeIfNecessary: false)
            (view as? SearchRowView)?.isCurrent = (index == table.selectedRow)
        }
    }

    /// The arrow swallows the click, so the row's own action never fires and
    /// the app is not launched out from under the menu.
    @objc private func arrowClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        showOptions(for: row)
    }

    @objc private func rowClicked() {
        activateSelection()
    }

    private func activateSelection() {
        let index = table.selectedRow
        if index == addRowIndex && showsAddRow {
            browseForApps()
            return
        }
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if let quick = row.quick {
            dismissThen { quick.perform() }
            return
        }
        // The configured entry when there is one, so a launch-only app picked
        // here behaves as it does from its shortcut.
        let entry = source().first { $0.bundleID == row.bundleID }
            ?? AppEntry(name: row.name, bundleID: row.bundleID)
        dismissThen { [onPick, activeBeforeShow] in
            onPick(entry, activeBeforeShow)
        }
    }

    /// Closing a key window makes macOS restore focus to whatever was active
    /// before us, and it does that asynchronously -- activating the target
    /// synchronously here loses the race and the old app wins. Let the restore
    /// happen, then take focus.
    private func dismissThen(_ work: @escaping () -> Void) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Options

    /// NSMenuItem carries no closure, and threading a dozen unrelated actions
    /// through tags and one selector is worse than this.
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, _ handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func fire() { handler() }
    }

    /// AppKit runs the contextual menu's own event loop, which costs the
    /// panel key status -- without this the panel would dismiss itself the
    /// moment you right-clicked, taking the menu with it.
    func menuWillOpen(_ menu: NSMenu) {
        optionsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        optionsOpen = false
        if isVisible {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
        }
    }

    /// Right-click on a result. Same actions as the arrow, with Quit at the
    /// top: reaching for the context menu on a running app is almost always
    /// about closing it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clicked = table.clickedRow
        let index = clicked >= 0 ? clicked : table.selectedRow
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)

        // Items can only belong to one menu, so detach them from the freshly
        // built source before re-adding.
        let source = optionsMenu(for: rows[index], quitFirst: true)
        let items = source.items
        source.removeAllItems()
        items.forEach { menu.addItem($0) }
    }

    /// Everything you might want to do to the highlighted app, rather than
    /// only the one thing Return does.
    private func showOptions(for index: Int) {
        guard rows.indices.contains(index), rows[index].quick == nil else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)

        let menu = optionsMenu(for: rows[index])
        let rowRect = table.rect(ofRow: index)
        let anchor = NSPoint(x: rowRect.maxX - sidePadding - arrowWidth, y: rowRect.maxY)

        optionsOpen = true
        menu.popUp(positioning: nil, at: anchor, in: table)   // blocks until dismissed
        optionsOpen = false

        // A pick may have closed the panel on its way out; only take focus
        // back if it is still up.
        if isVisible {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
        }
    }

    private func optionsMenu(for row: Row, quitFirst: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let entry = AppEntry(name: row.name, bundleID: row.bundleID)
        let running = WindowControl.runningApp(row.bundleID)

        func quitItem(_ app: NSRunningApplication) -> ActionItem {
            ActionItem(localized("Quit %0", row.name)) { [weak self] in
                WindowControl.quit(app)
                Notify.show("Quit \(row.name)", symbol: "xmark.circle.fill")
                self?.refresh(after: 0.6)
            }
        }

        if quitFirst, let running {
            menu.addItem(quitItem(running))
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem(running == nil ? localized("Open") : localized("Bring to Front")) { [weak self] in
            self?.dismissThen { WindowControl.bringToFront(entry) }
        })

        if let running {
            // Ahead of the window list: opening a new one is the more common
            // want, and the list below is for going back to an existing one.
            menu.addItem(ActionItem(localized("New Window")) { [weak self] in
                self?.dismissThen {
                    if !WindowControl.newWindow(running) {
                        Notify.show("\(row.name) has no New Window command")
                    }
                }
            })

            let windows = WindowControl.windowList(for: running)
            if windows.count > 1 {
                menu.addItem(.separator())
                let header = NSMenuItem(title: localized("Windows"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for window in windows {
                    let mark = window.isMinimized ? "\u{25CB}" : "\u{25CF}"
                    menu.addItem(ActionItem("\(mark)  \(window.title)") { [weak self] in
                        self?.dismissThen { WindowControl.raise(window, of: running) }
                    })
                }
            }

            menu.addItem(.separator())
            switch row.state {
            case .minimized:
                menu.addItem(ActionItem(localized("Restore")) { [weak self] in
                    self?.dismissThen { _ = WindowControl.restore(row.bundleID) }
                })
            case .visible, .fullScreen:
                menu.addItem(ActionItem(localized("Minimise")) { [weak self] in
                    WindowControl.minimize(row.bundleID)
                    self?.refresh()
                })
                menu.addItem(ActionItem(localized("Hide")) { [weak self] in
                    WindowControl.hide(running)
                    self?.refresh()
                })
            case .noWindow, .notRunning:
                break
            }
            if !quitFirst {
                menu.addItem(quitItem(running))
            }
        }

        menu.addItem(.separator())
        // The custom switcher: Ctrl+Tab walks only the marked apps.
        let marked = isMarked(row.bundleID)
        let markItem = ActionItem(marked ? localized("Remove from ⌃Tab Switcher") : localized("Add to ⌃Tab Switcher")) { [weak self] in
            self?.onSetMarked(entry, !marked)
            self?.refresh()
        }
        markItem.state = marked ? .on : .off
        menu.addItem(markItem)

        menu.addItem(.separator())
        let listed = source().contains { $0.bundleID == row.bundleID }
        menu.addItem(ActionItem(listed ? localized("Remove from My Apps") : localized("Add to My Apps")) { [weak self] in
            self?.onSetListed([entry], !listed)
            self?.refresh()
        })
        let reveal = ActionItem(localized("Reveal in Finder")) { [weak self] in
            self?.dismissThen { WindowControl.revealInFinder(row.bundleID) }
        }
        // An alternate pairs with the item before it only when their key
        // equivalents match but for the modifiers -- here, none and ⌥.
        reveal.keyEquivalentModifierMask = []
        menu.addItem(reveal)
        // A developer's item, so it is the ⌥ alternate of the one above
        // rather than a line of its own beside Quit and Reveal in Finder.
        let copyID = ActionItem(localized("Copy Bundle ID")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.bundleID, forType: .string)
        }
        copyID.isAlternate = true
        copyID.keyEquivalentModifierMask = .option
        menu.addItem(copyID)

        menu.addItem(.separator())
        menu.addItem(ActionItem(localized("Add an App…")) { [weak self] in
            self?.browseForApps()
        })
        // With no status-bar menu of its own, the panel is where the list gets
        // managed from.
        menu.addItem(ActionItem(localized("Edit Apps…")) { [weak self] in
            guard let self else { return }
            self.hide()
            DispatchQueue.main.async { self.onEditApps() }
        })
        return menu
    }

    /// Pick an app from disk and add it to the list. The picker is an ordinary
    /// window that needs focus, and the panel is holding it, so hand it over
    /// and stay down afterwards rather than reappearing over the dialog.
    private func browseForApps() {
        hide()
        // One turn later, so the options menu's own event loop has finished
        // before a modal-ish window opens on top of it.
        DispatchQueue.main.async { [weak self] in
            AppChooser.run { added in
                guard let self, !added.isEmpty else { return }
                self.onSetListed(added, true)
            }
        }
    }

    /// Re-read the app states after an action that changed one, keeping the
    /// user on the same row.
    private func refresh(after delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isVisible else { return }
            self.reload(keepingSelection: true)
        }
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1); return true
        // Tab walks the list the way Cmd-Tab does, so switching apps is one
        // key held and tapped rather than a reach for the arrows. With no
        // query the list is already in most-recently-used order.
        // Tab cycles rather than stopping at the ends: it is being used as a
        // switcher key here, and a switcher that refuses to come back round
        // to the top is a switcher you have to notice the end of.
        case #selector(NSResponder.insertTab(_:)):
            move(by: 1, wrapping: true); return true
        case #selector(NSResponder.insertBacktab(_:)):
            move(by: -1, wrapping: true); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(); return true
        case #selector(NSResponder.moveRight(_:)):
            // Only once the caret has nowhere left to go, so the arrow keeps
            // working as a caret key while there is text to walk through.
            let caret = textView.selectedRange()
            guard caret.length == 0,
                  caret.location == (textView.string as NSString).length else { return false }
            showOptions(for: table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func move(by delta: Int, wrapping: Bool = false) {
        let count = numberOfRows(in: table)
        guard count > 0 else { return }
        let current = table.selectedRow
        let next: Int
        if wrapping {
            // selectedRow is -1 when nothing is selected, which must not turn
            // a Tab into a jump to the last row.
            next = ((max(current, 0) + delta) % count + count) % count
        } else {
            next = max(0, min(count - 1, current + delta))
        }
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
}
