import AppKit
import UniformTypeIdentifiers

/// Editor for the app list: drag rows to reorder, add what is running,
/// remove what you don't want, set a Ctrl+digit shortcut inline.
///
/// This is the replacement for hand-editing apps.json.
final class AppsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private static let rowType = NSPasteboard.PasteboardType("com.sagar.roost.row")
    /// Marks the one ＋ entry that opens a file picker instead of naming an app.
    private static let browseTag = 1

    private var entries: [AppEntry]
    private let onChange: ([AppEntry]) -> Void
    private let table = SingleColumnTableView()

    init(entries: [AppEntry], onChange: @escaping ([AppEntry]) -> Void) {
        self.entries = entries
        self.onChange = onChange

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = localized("My Apps")
        window.center()
        super.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table

        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.translatesAutoresizingMaskIntoConstraints = false
        add.addItem(withTitle: "＋")
        add.toolTip = localized("Add an app")
        add.target = self
        add.action = #selector(addPicked(_:))

        let remove = NSButton(title: "－", target: self, action: #selector(removeSelected))
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.bezelStyle = .rounded
        remove.toolTip = localized("Remove the selected app")

        // It said "⌃1–⌃9 follow the first nine", which they do not: a key
        // belongs to the app it was given to, wherever that app is dragged.
        let hint = NSTextField(labelWithString: localized("Drag to change the order in search · choose each app's shortcut on the right"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(add)
        content.addSubview(remove)
        content.addSubview(hint)
        window.contentView = content

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -10),

            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            add.widthAnchor.constraint(equalToConstant: 52),

            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 40),

            hint.leadingAnchor.constraint(equalTo: remove.trailingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        rebuildAddMenu()
        table.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Data

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]

        let container = NSView()
        let icon = NSImageView()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: entry.name)
        name.translatesAutoresizingMaskIntoConstraints = false

        // A menu of the keys that work, not a text box. The box took any
        // character and saved it, but `Hotkey.Key.code(for:)` knows only
        // digits, ` and ; -- so ⌃S for Safari was kept, shown, and never
        // fired. A key another app has says whose it is, and picking it
        // moves it here rather than leaving two apps on one key.
        let shortcut = NSPopUpButton(frame: .zero, pullsDown: false)
        shortcut.controlSize = .small
        shortcut.addItem(withTitle: localized("None"))
        for key in Self.shortcutKeys {
            let owner = entries.first { $0.shortcut == key && $0.bundleID != entry.bundleID }
            shortcut.addItem(withTitle: owner.map { "⌃\(key)  —  \($0.name)" } ?? "⌃\(key)")
            shortcut.lastItem?.representedObject = key
        }
        if let key = entry.shortcut, let index = Self.shortcutKeys.firstIndex(of: key) {
            shortcut.selectItem(at: index + 1)
        }
        shortcut.tag = row
        shortcut.target = self
        shortcut.action = #selector(shortcutPicked(_:))
        shortcut.toolTip = localized("Press this anywhere to open or switch to the app")
        shortcut.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(name)
        container.addSubview(shortcut)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            shortcut.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            shortcut.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: 72),
            name.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8)
        ])
        return container
    }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation)
    -> NSDragOperation {
        operation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.rowType),
              let from = Int(text), entries.indices.contains(from) else { return false }

        let moved = entries.remove(at: from)
        // removing shifts everything after it up by one
        let target = from < row ? row - 1 : row
        entries.insert(moved, at: min(max(target, 0), entries.count))

        table.reloadData()
        table.selectRowIndexes([min(max(target, 0), entries.count - 1)], byExtendingSelection: false)
        commit()
        return true
    }

    // MARK: - Add / remove / edit

    private func rebuildAddMenu() {
        guard let button = window?.contentView?.subviews
                .compactMap({ $0 as? NSPopUpButton }).first else { return }
        button.removeAllItems()
        button.addItem(withTitle: "＋")            // title row for a pull-down

        // First, because the running apps below cannot cover an app that has
        // never been opened -- which is most of what you come here to add.
        let browse = NSMenuItem(title: localized("Choose from Applications…"),
                                action: nil, keyEquivalent: "")
        browse.tag = Self.browseTag
        button.menu?.addItem(browse)

        button.menu?.addItem(.separator())

        let known = Set(entries.map(\.bundleID))
        for app in WindowControl.runningRegularApps() {
            guard let bundleID = app.bundleIdentifier, !known.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            // An app with no name is left out rather than shown as its
            // bundle identifier; "Choose from Applications…" still reaches it.
            guard let name = app.localizedName else { continue }
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.image = app.icon.map { icon in
                let small = icon.copy() as? NSImage ?? icon
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            item.representedObject = bundleID
            button.menu?.addItem(item)
        }
    }

    @objc private func addPicked(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }

        if item.tag == Self.browseTag {
            AppChooser.run { [weak self] added in
                guard let self else { return }
                self.append(added)
                // The picker took focus; come back to the editor.
                self.window?.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard let bundleID = item.representedObject as? String else { return }
        append([AppEntry(name: item.title, bundleID: bundleID)])
    }

    private func append(_ added: [AppEntry]) {
        var known = Set(entries.map(\.bundleID))
        let fresh = added.filter { known.insert($0.bundleID).inserted }
        guard !fresh.isEmpty else { return }

        entries.append(contentsOf: fresh)
        table.reloadData()
        rebuildAddMenu()
        commit()
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        entries.remove(at: row)
        table.reloadData()
        rebuildAddMenu()
        commit()
    }

    /// The keys `Hotkey.Key.code(for:)` can register with ⌃, in the order
    /// they sit on the keyboard.
    static let shortcutKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "`", ";"]

    @objc private func shortcutPicked(_ sender: NSPopUpButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let key = sender.selectedItem?.representedObject as? String
        if let key {
            for index in entries.indices where entries[index].shortcut == key { entries[index].shortcut = nil }
        }
        entries[sender.tag].shortcut = key
        // Every row's menu names the owners, so all of them change.
        table.reloadData()
        commit()
    }

    private func commit() {
        Config.save(entries)
        onChange(entries)
    }
}
