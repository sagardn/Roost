import AppKit

/// What the application shell needs of the storage module.
extension DiskModule: RoostModule {

    var moduleName: String { "Disk" }

    /// A Mac with no browsable volume is a Mac that is not running, but a
    /// module that claims to be available and then shows a dash is worse
    /// than one that says it has nothing.
    ///
    /// Cached, because this is read once a second and cost 6.16 ms a read.
    /// `MonitorBar` ticks every second and asks the registry which modules
    /// are enabled *and available*, which called this; enumerating every
    /// mounted volume goes through CacheDelete's volume validation, and that
    /// was the single hottest thing in a 20-second sample of the idle app.
    /// The answer changes only when a volume is mounted or unmounted, so
    /// that is when it is thrown away.
    var isAvailable: Bool {
        if let known = DiskAvailability.cached { return known }
        DiskAvailability.observe()
        let answer = !DiskReadings.volumes(includingRemovable: true).isEmpty
        DiskAvailability.cached = answer
        return answer
    }

    /// On, as the module it replaces was.
    var isOnByDefault: Bool { true }

    var hasPreview: Bool { false }

    var isEnabled: Bool {
        get { DiskSettings.isEnabled }
        set {
            guard newValue != DiskSettings.isEnabled else { return }
            DiskSettings.isEnabled = newValue
            newValue ? MonitorBar.shared.show(self) : MonitorBar.shared.hide(moduleName)
        }
    }

    func start() {
        guard isEnabled else { return }
        MonitorBar.shared.show(self)
    }

    func stop() {
        willStop()
        MonitorBar.shared.hide(moduleName)
    }

    var popupShortcut: [UInt16] { DiskSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { DiskSettingsPage() }
}

/// Storage's own preferences, under the keys the module it replaces used.
enum DiskSettings {
    private static let prefs = Preferences.shared

    static var isEnabled: Bool {
        get { prefs.bool("Disk_state", default: true) }
        set { prefs.set("Disk_state", newValue) }
    }

    /// Whether to count removable drives. Off, as it was: a USB stick
    /// plugged in for a minute should not rearrange the menu bar.
    static var showsRemovable: Bool {
        get { prefs.bool("Disk_removable", default: false) }
        set { prefs.set("Disk_removable", newValue) }
    }

    static var historyLength: Int {
        get { prefs.int("Disk_historyLength", default: 120) }
        set { prefs.set("Disk_historyLength", newValue) }
    }

    /// Which volume the menu bar figure is about, as a mount point. Empty
    /// means the startup volume.
    ///
    /// `Disk_volume` is canonical. Two other keys have held this setting and
    /// both are read once and retired -- see `migrateChosenVolume`.
    static var watchedVolume: String {
        get {
            migrateChosenVolume()
            return prefs.string("Disk_volume", default: "")
        }
        set { prefs.set("Disk_volume", newValue) }
    }

    /// Brings a volume choice stored under an older key up to date.
    ///
    /// Three keys have held this setting, because it was built twice:
    ///
    /// - `Disk_volume` -- canonical, a mount point.
    /// - `Disk_selectedDisk` -- a mount point, from a second implementation
    ///   written in parallel. Anyone who ran that build has one.
    /// - `Disk_disk` -- the original module's, and a **name** rather than a
    ///   path. Two drives called "Backup" are entirely possible and a name
    ///   cannot tell them apart, which is why neither rebuild kept it.
    ///
    /// The precedence is strict and the reason matters: a value already
    /// under the canonical key is a choice the user made *here*, and is
    /// never overwritten by an older key that also happens to exist. Only an
    /// absent canonical value is filled in, newer source first.
    ///
    /// Both old keys are removed once read, whether or not they yielded
    /// anything, so this costs one `object(forKey:)` after the first launch.
    private static func migrateChosenVolume() {
        let legacyNameKey = "Disk_disk"
        let parallelPathKey = "Disk_selectedDisk"
        guard prefs.exists(legacyNameKey) || prefs.exists(parallelPathKey) else { return }

        defer {
            prefs.set(legacyNameKey, nil)
            prefs.set(parallelPathKey, nil)
        }

        // The decision itself is `DiskReadings.resolveWatchedVolume`, which
        // is pure and tested; this reads the keys and writes the answer.
        if let resolved = DiskReadings.resolveWatchedVolume(
            canonical: prefs.string("Disk_volume", default: ""),
            parallel: prefs.string(parallelPathKey, default: ""),
            legacyName: prefs.string(legacyNameKey, default: ""),
            mounted: DiskReadings.volumes(includingRemovable: true)) {
            prefs.set("Disk_volume", resolved)
        }
    }

    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "Disk_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }
}

/// The storage page in Settings.
final class DiskSettingsPage: NSView {

    private var shown: Set<MenuBarStyle>
    private let styles = DiskModule().menuBarStyles

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "Disk"))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        // The volumes that exist right now, plus whatever is stored, so a
        // chosen drive that is currently unplugged still shows as chosen.
        let mounted = DiskReadings.volumes(includingRemovable: true)
        var choices: [(String, String)] = [(localized("Startup volume"), "")]
        choices += mounted.map { ($0.name, $0.path) }
        let chosen = DiskSettings.watchedVolume
        if !chosen.isEmpty, !mounted.contains(where: { $0.path == chosen }) {
            choices.append(("\(chosen) (\(localized("not mounted")))", chosen))
        }

        let popup = Controls.section(localized("Show in the popup"), [
            Controls.row(localized("Include removable drives"),
                         Controls.toggle(DiskSettings.showsRemovable) { on in
                             DiskSettings.showsRemovable = on
                         }),
            Controls.row(localized("Chart history"), Controls.choice(
                [("1 minute", "60"), ("2 minutes", "120"), ("5 minutes", "300")],
                selected: "\(DiskSettings.historyLength)") { value in
                    DiskSettings.historyLength = Int(value) ?? 120
                })
        ])

        // Grouped by where each setting shows -- the menu bar item, the popup
        // it opens, then notifications -- rather than under a heading that
        // repeated the page title. The shortcut opens the popup from the
        // keyboard, so it sits with the item it stands in for a click on.
        // "Watch" is here too: it picks the volume the menu bar figure is about.
        let shapes = Controls.section(
            localized("Menu bar"),
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "Disk")),
             Controls.row(localized("Watch"), Controls.choice(choices, selected: chosen) { value in
                 DiskSettings.watchedVolume = value
             }),
             Controls.shapes(styles, shown: shown, label: DiskModule().menuBarLabel) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "Disk")
            }])

        let alerts = Controls.section(localized("Notify me when"),
            DiskThreshold.allCases.map { threshold in
                Controls.row(threshold.title,
                             Controls.threshold(on: threshold.isWatched,
                                                value: threshold.level,
                                                suffix: threshold.scale.suffix,
                                                range: threshold.range,
                                                step: threshold.step) { on, level in
                    threshold.isWatched = on
                    threshold.level = level
                })
            })

        let column = NSStackView(views: [shapes, popup, alerts])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 44, left: 18, bottom: 18, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            popup.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            shapes.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            alerts.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Remembers whether any volume is mounted, and forgets when one comes or
/// goes.
///
/// A plain static rather than a property on the module: `DiskModule` is a
/// class whose instances the registry holds one of, and the question is
/// about the machine rather than about any instance of it.
enum DiskAvailability {

    static var cached: Bool?

    private static var observing = false

    /// Registered on the first read rather than at launch, so a Mac that
    /// never looks at the Disk module never registers anything.
    static func observe() {
        guard !observing else { return }
        observing = true
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                cached = nil
            }
        }
    }
}
