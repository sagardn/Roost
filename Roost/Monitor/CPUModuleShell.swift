import AppKit

/// What the application shell needs of the CPU module.
///
/// `CPUModule` is the reading and the popup; this is the part the shell talks
/// to — the name, the switch, the lifecycle, the settings page and the tile.
/// Kept in its own file so the popup stays about processors and this stays
/// about plumbing.
///
/// The menu bar item is `MonitorBar`'s, asked for by name. Owning a second
/// `NSStatusItem` here would mean two items for one reading.
extension CPUModule: RoostModule {

    var moduleName: String { "CPU" }

    /// Every Mac has a processor.
    var isAvailable: Bool { true }

    var isOnByDefault: Bool { true }

    /// No settings preview yet. Offering the button for a preview that does
    /// not exist is worse than not offering it.
    var hasPreview: Bool { false }

    /// Stored under `CPU_state`, the key the module it replaces used, so a Mac
    /// that has been running Roost keeps the user's choice.
    var isEnabled: Bool {
        get { CPUSettings.isEnabled }
        set {
            guard newValue != CPUSettings.isEnabled else { return }
            CPUSettings.isEnabled = newValue
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

    var popupShortcut: [UInt16] { CPUSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    /// The tile the combined details popup stacks.
    ///
    /// Made on the first ask and kept, because the module refreshes it in
    /// place -- and only while it is on screen, so a tile nobody is looking
    /// at costs nothing. Before this, CPU was the one module with no tile,
    /// which would have taken the processor out of the details popup the
    /// moment it stopped being Kit's.
    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { CPUSettingsPage() }
}

/// CPU's own preferences.
///
/// Three things the popup genuinely varies by, each under the module's name so
/// they sit beside the settings the rest of the app stores.
enum CPUSettings {
    private static let prefs = Preferences.shared

    static var isEnabled: Bool {
        get { prefs.bool("CPU_state", default: true) }
        set { prefs.set("CPU_state", newValue) }
    }

    /// Hiding it is for Macs where the sensor reads nothing useful, and for
    /// anyone who would rather have the width back.
    static var showsTemperature: Bool {
        get { prefs.bool("CPU_showsTemperature", default: true) }
        set { prefs.set("CPU_showsTemperature", newValue) }
    }

    /// Samples kept in the usage chart. One per second, so 120 is two minutes.
    static var historyLength: Int {
        get { prefs.int("CPU_historyLength", default: 120) }
        set { prefs.set("CPU_historyLength", newValue) }
    }

    /// How many processes the popup lists. Zero stops `ProcessCPU` sampling
    /// altogether, which is the expensive part of the popup.
    static var processCount: Int {
        get { prefs.int("CPU_processCount", default: 8) }
        set { prefs.set("CPU_processCount", newValue) }
    }

    /// Virtual key codes that open the popup. Empty is none, which is the
    /// default — see `syncPopupKeyMonitor`, which only arms a global keyboard
    /// monitor while some module has one set.
    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "CPU_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }
}

/// The CPU page in Settings.
final class CPUSettingsPage: NSView {

    /// The shapes ticked, held while the page is open so six switches can
    /// edit one stored list without each reading it back first.
    private var shown: Set<MenuBarStyle>
    /// Only the shapes this module can fill.
    private let styles = CPUModule().menuBarStyles

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "CPU"))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        let shapes = Controls.section(
            localized("Menu bar"), symbol: "menubar.rectangle", tint: .systemBlue,
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.shapes(self.styles, shown: self.shown, label: CPUModule().menuBarLabel,
                             value: "42%", ) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "CPU")
            }])

        // One app on its own, not the machine: the case this is for was an
        // app holding 59% of a core while the total sat at a modest 30%.
        // The duration is read, not written into the sentence: it is a
        // stored preference with a range of 1 to 60, and the label said
        // "5 minutes" whatever it was set to. "This busy" meant the figure
        // in the stepper beside it, which only works if the sentence says
        // so.
        let runaway = Controls.row(
            localized("One app stays busy"),
            Controls.threshold(on: RunawayApps.isEnabled,
                               value: RunawayApps.threshold,
                               suffix: "%", range: 20...400, step: 10) { on, level in
                RunawayApps.threshold = level
                RunawayApps.isEnabled = on
            },
            detail: localized("Notified once when a single app holds at least this share of one core for %0 minutes.",
                              String(RunawayApps.minutes)))

        // What throttling is, in the words somebody would use for it: the
        // row named the symptom and never said what causes it or that it
        // ends by itself.
        let throttling = Controls.row(
            localized("The Mac slows down to cool off"),
            Controls.toggle(Throttling.alertsEnabled) { Throttling.alertsEnabled = $0 },
            detail: localized("macOS lowers the processor's speed when the Mac runs hot, and raises it again once it cools."))
        let alerts = Controls.section(localized("Notify me when"), symbol: "bell.badge.fill",
                                      tint: .systemRed,
            CPUThreshold.allCases.filter { $0.isAvailable }.map { threshold in
                Controls.row(threshold.title,
                             Controls.threshold(on: threshold.isWatched,
                                                value: threshold.level,
                                                suffix: threshold.scale.suffix,
                                                range: threshold.range,
                                                step: threshold.step) { on, level in
                    threshold.isWatched = on
                    threshold.level = level
                })
            } + [runaway, throttling])

        let section = Controls.section(localized("CPU"), symbol: "cpu.fill", tint: .systemBlue, [
            Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "CPU")),
            Controls.row(localized("Show temperature"),
                         Controls.toggle(CPUSettings.showsTemperature) { on in
                             CPUSettings.showsTemperature = on
                         }),
            Controls.row(localized("Chart history"), Controls.choice(
                [("1 minute", "60"), ("2 minutes", "120"), ("5 minutes", "300")],
                selected: "\(CPUSettings.historyLength)") { value in
                    CPUSettings.historyLength = Int(value) ?? 120
                }),
            Controls.row(localized("Top processes"), Controls.choice(
                [("None", "0"), ("5", "5"), ("8", "8"), ("12", "12")],
                selected: "\(CPUSettings.processCount)") { value in
                    CPUSettings.processCount = Int(value) ?? 8
                })
        ])

        let column = NSStackView(views: [section, shapes, alerts])
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
            section.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            shapes.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            alerts.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
