import AppKit
import Combine

/// The Clipboard page in Settings.
///
/// Monitoring first, on a card of its own, because it is the one switch that
/// decides whether anything else here does anything; then what is captured,
/// how long it is kept, how it is reached, what is left out, and the
/// destructive actions last and apart.
///
/// Rows that depend on another are disabled, not hidden, while it is off,
/// and the section's footer says why -- a row that vanished would leave
/// somebody looking for a setting that is not there.
final class ClipboardSettingsPage: NSView {

    private var observers: [NSObjectProtocol] = []
    private var watching: AnyCancellable?
    private var dependents: [(control: NSControl, enabled: () -> Bool)] = []
    private var refreshers: [() -> Void] = []
    private let monitoringSwitch: ActionSwitch
    private let excludedList = NSStackView()

    init() {
        monitoringSwitch = Controls.toggle(ClipboardSettings.monitoring) { on in
            if on {
                ClipboardActions.enableMonitoring()
            } else {
                ClipboardSettings.monitoring = false
            }
        } as! ActionSwitch
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let sections = [historySection(), captureSection(), keepingSection(), reachSection(),
                        privacySection(), clearSection()]
        let column = NSStackView(views: sections)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = RoostMetrics.sectionSpacing
        column.edgeInsets = NSEdgeInsets(top: RoostMetrics.pageTop, left: RoostMetrics.pageInset,
                                         bottom: RoostMetrics.pageInset, right: RoostMetrics.pageInset)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        var constraints = [
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor)
        ]
        constraints += sections.map {
            $0.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -RoostMetrics.pageInset * 2)
        }
        NSLayoutConstraint.activate(constraints)

        // The privacy note can be cancelled, the service changes state on its
        // own, and the sidebar switch moves the menu bar item: all three
        // change what this page should say without it being touched.
        observers.append(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] note in
                guard ClipboardSettings.isClipboardKey(note.object as? String) else { return }
                self?.sync()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .toggleModule, object: nil, queue: .main) { [weak self] _ in self?.sync() })
        // And the service's own changes -- a copy landing, the status moving
        // -- which arrive after the settings that caused them. `willChange`
        // fires before the value moves, so the read waits a turn.
        watching = ClipboardService.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Sections

    private func historySection() -> NSView {
        let status = Controls.label("")
        let stored = Controls.label("")
        let access = Controls.label("")
        refreshers.append {
            let service = ClipboardService.shared
            switch service.status {
            case .on:      status.stringValue = localized("Recording copies")
            case .off:     status.stringValue = localized("Off")
            case .blocked: status.stringValue = localized("Blocked by macOS")
            }
            stored.stringValue = localized("%0 entries · %1", "\(service.history.entries.count)",
                                           ClipboardFormat.bytes(service.history.byteSize))
            access.stringValue = ClipboardActions.accessDescription
        }
        return Controls.section(localized("Clipboard history"), symbol: "doc.on.clipboard.fill",
                                tint: .systemTeal,
                                footer: localized("Kept on this Mac only and never sent anywhere. Turning it off stops capturing and keeps what is already there."), [
            Controls.row(localized("Enable clipboard history"), monitoringSwitch,
                         detail: localized("Keeps what you copy so you can use it again.")),
            Controls.row(localized("Status"), status),
            Controls.row(localized("Kept"), Controls.group([
                stored, Controls.button("Open history…") {
                    ClipboardHistoryWindow.present(over: ClipboardActions.otherFrontmostApp)
                }])),
            Controls.row(localized("Reading the clipboard"), Controls.group([
                access, Controls.button("Privacy & Security…") { ClipboardActions.openPrivacySettings() }]),
                         detail: localized("macOS decides whether apps may read what you copy, under Paste from Other Apps."))
        ])
    }

    private func captureSection() -> NSView {
        let text = dependent(Controls.toggle(ClipboardSettings.captureText) { ClipboardSettings.captureText = $0 }) {
            ClipboardSettings.monitoring
        }
        let images = dependent(Controls.toggle(ClipboardSettings.captureImages) { ClipboardSettings.captureImages = $0 }) {
            ClipboardSettings.monitoring
        }
        let rich = dependent(Controls.toggle(ClipboardSettings.keepRichText) { ClipboardSettings.keepRichText = $0 }) {
            ClipboardSettings.monitoring && ClipboardSettings.captureText
        }
        let previews = dependent(Controls.toggle(ClipboardSettings.showImagePreviews) {
            ClipboardSettings.showImagePreviews = $0
        }) { ClipboardSettings.captureImages }
        let paste = Controls.toggle(ClipboardSettings.autoPaste) { ClipboardSettings.autoPaste = $0 }

        return Controls.section(localized("Capture"), symbol: "square.and.arrow.down.fill", tint: .systemBlue,
                                footer: localized("What is kept while history is on. Turn history on to change it."), [
            Controls.row(localized("Text, links and files"), text),
            Controls.row(localized("Keep formatting"), rich, indented: true,
                         detail: localized("Rich text and web formatting, restored with the text.")),
            Controls.row(localized("Images"), images,
                         detail: localized("Up to 25 MB each. Larger images are left out rather than shrunk.")),
            Controls.row(localized("Show image previews"), previews, indented: true),
            Controls.row(localized("Paste for me"), paste,
                         detail: localized("Choosing an entry also pastes it into the app you were in. Needs window control; otherwise it is copied for you to paste."))
        ])
    }

    private func keepingSection() -> NSView {
        let limit = Controls.choice([("50", "50"), ("100", "100"), ("200", "200"), ("500", "500"), ("1000", "1000")],
                                    selected: "\(ClipboardSettings.maximumEntries)") {
            ClipboardSettings.maximumEntries = Int($0) ?? 200
        }
        let retention = Controls.choice([("1 day", "1"), ("1 week", "7"), ("30 days", "30"),
                                         ("90 days", "90"), ("Never", "0")],
                                        selected: "\(ClipboardSettings.retentionDays)") {
            ClipboardSettings.retentionDays = Int($0) ?? 30
        }
        let pins = dependent(Controls.toggle(ClipboardSettings.retentionIncludesPinned) {
            ClipboardSettings.retentionIncludesPinned = $0
        }) { ClipboardSettings.retentionDays > 0 }
        let persistent = Controls.toggle(ClipboardSettings.persistent) { ClipboardSettings.persistent = $0 }
        let clearOnQuit = dependent(Controls.toggle(ClipboardSettings.clearUnpinnedOnQuit) {
            ClipboardSettings.clearUnpinnedOnQuit = $0
        }) { ClipboardSettings.persistent }

        return Controls.section(localized("Keeping"), symbol: "clock.fill", tint: .systemIndigo,
                                footer: localized("Pinned entries are never pushed out by the limit, and expire only if you choose. Limits apply as soon as they are changed."), [
            Controls.row(localized("Keep at most"), limit, detail: localized("Entries, not counting pinned ones.")),
            Controls.row(localized("Remove entries after"), retention),
            Controls.row(localized("Pinned entries expire too"), pins, indented: true),
            Controls.row(localized("Keep history after quitting"), persistent,
                         detail: localized("Off, history lasts until Roost quits and is then deleted.")),
            Controls.row(localized("Clear unpinned entries when Roost quits"), clearOnQuit, indented: true)
        ])
    }

    private func reachSection() -> NSView {
        let module = ClipboardModule.shared
        let inMenuBar = Controls.toggle(module.isEnabled) { on in
            // The sidebar's switch, by another way in: the same notification,
            // so the two never disagree.
            module.isEnabled = on
            if !on { module.stop() }
            NotificationCenter.default.post(name: .toggleModule, object: nil,
                                            userInfo: ["module": module.moduleName, "state": on])
        } as! ActionSwitch
        refreshers.append { inMenuBar.state = module.isEnabled ? .on : .off }
        let count = Controls.choice([("5", "5"), ("8", "8"), ("12", "12")],
                                    selected: "\(ClipboardSettings.popupCount)") {
            ClipboardSettings.popupCount = Int($0) ?? 8
        }
        return Controls.section(localized("Menu bar and shortcut"), symbol: "menubar.rectangle",
                                tint: .systemBlue,
                                footer: localized("The menu bar item and history are separate: history keeps working with the item hidden."), [
            Controls.row(localized("Show in the menu bar"), inMenuBar),
            Controls.row(localized("Entries in the popup"), count),
            Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "Clipboard"),
                         detail: localized("Opens the popup, or the history window while the item is hidden. Works in other apps once window control is allowed."))
        ])
    }

    private func privacySection() -> NSView {
        excludedList.orientation = .vertical
        excludedList.alignment = .leading
        excludedList.spacing = 4
        excludedList.translatesAutoresizingMaskIntoConstraints = false
        refreshers.append { [weak self] in self?.fillExclusions() }

        return Controls.section(localized("Privacy"), symbol: "hand.raised.fill", tint: .systemGreen,
                                footer: localized(
                                    "Copies an app marks as private, as password managers do, are never kept. Roost can tell which app was in front when a copy was made, not which app made it."), [
            Controls.row(localized("Ignore copies made in"), Controls.button("Add App…") { [weak self] in
                self?.addExclusion()
            }),
            Controls.row(excludedList)
        ])
    }

    private func clearSection() -> NSView {
        func confirm(_ title: String, _ detail: String, _ action: @escaping () -> Void) {
            Alert.show(title, detail, style: .warning, actionTitle: localized("Clear"), action: action)
        }
        return Controls.section(localized("Clear and reset"), symbol: "trash.fill", tint: .systemRed, [
            Controls.row(localized("History"), Controls.group([
                Controls.button("Clear Unpinned…") {
                    confirm(localized("Clear everything that is not pinned?"),
                            localized("The entries and their stored images are deleted from this Mac. This cannot be undone.")) {
                        ClipboardService.shared.clear(keepingPinned: true)
                    }
                },
                Controls.button("Clear All…") {
                    confirm(localized("Clear the whole clipboard history?"),
                            localized("The entries and their stored images are deleted from this Mac. This cannot be undone.")) {
                        ClipboardService.shared.clear(keepingPinned: false)
                    }
                }
            ])),
            Controls.row(localized("Settings"), Controls.button("Restore Defaults") {
                ClipboardSettings.restoreDefaults()
            }, detail: localized("Capture, keeping and popup options. Leaves history on or off, the menu bar item, the shortcut and every entry as they are."))
        ])
    }

    // MARK: - Exclusions

    private func fillExclusions() {
        excludedList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ids = ClipboardSettings.excludedApps
        if ids.isEmpty {
            excludedList.addArrangedSubview(Controls.label(localized("No apps")))
        }
        // By name, with the app's icon: sorted by identifier, "com.1password"
        // came before "com.apple" and the list read in no order anyone sees.
        let apps = ids.map { id -> (id: String, url: URL?, name: String) in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension } ?? id
            return (id, url, name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for (id, url, name) in apps {
            let icon = NSImageView()
            icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let label = NSTextField(labelWithString: url == nil ? localized("%0 (not installed)", name) : name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = url == nil ? .secondaryLabelColor : .labelColor
            let remove = ActionButton()
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: localized("Remove %0", name))
            remove.isBordered = false
            remove.toolTip = localized("Remove %0", name)
            remove.onPress = {
                ClipboardSettings.excludedApps = ClipboardSettings.excludedApps.filter { $0 != id }
            }
            let row = NSStackView(views: [remove, icon, label])
            row.spacing = 6
            excludedList.addArrangedSubview(row)
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        ClipboardSettings.excludedApps = Array(Set(ClipboardSettings.excludedApps + ids)).sorted()
    }

    // MARK: - State

    private func dependent(_ control: NSControl, when enabled: @escaping () -> Bool) -> NSControl {
        dependents.append((control, enabled))
        return control
    }

    private func sync() {
        monitoringSwitch.state = ClipboardSettings.monitoring ? .on : .off
        for (control, enabled) in dependents { control.isEnabled = enabled() }
        refreshers.forEach { $0() }
    }
}
