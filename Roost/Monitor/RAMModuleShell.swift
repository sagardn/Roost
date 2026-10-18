import AppKit

/// What the application shell needs of the memory module.
///
/// `RAMModule` is the reading and the popup; this is the name, the switch,
/// the lifecycle, the settings page and the tile. Kept apart so the popup
/// stays about memory and this stays about plumbing -- the same split CPU
/// uses, and the reason adding a module is now a short file rather than a
/// framework.
extension RAMModule: RoostModule {

    var moduleName: String { "RAM" }

    /// Every Mac has memory.
    var isAvailable: Bool { true }

    var isOnByDefault: Bool { true }

    var hasPreview: Bool { false }

    /// Stored under `RAM_state`, the key the module it replaces used.
    var isEnabled: Bool {
        get { RAMSettings.isEnabled }
        set {
            guard newValue != RAMSettings.isEnabled else { return }
            RAMSettings.isEnabled = newValue
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

    var popupShortcut: [UInt16] { RAMSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { RAMSettingsPage() }
}

/// Memory's own preferences.
enum RAMSettings {
    private static let prefs = Preferences.shared

    static var isEnabled: Bool {
        get { prefs.bool("RAM_state", default: true) }
        set { prefs.set("RAM_state", newValue) }
    }

    /// Samples kept in the usage chart. One per second.
    static var historyLength: Int {
        get { prefs.int("RAM_historyLength", default: 120) }
        set { prefs.set("RAM_historyLength", newValue) }
    }

    /// How many processes the popup lists. Zero stops `ProcessMemory`
    /// sampling altogether, which is the only subprocess this module runs.
    ///
    /// Under `RAM_processes`, the key the module it replaces used for the
    /// same setting and the same default.
    static var processCount: Int {
        get { prefs.int("RAM_processes", default: 8) }
        set { prefs.set("RAM_processes", newValue) }
    }

    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "RAM_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }
}

/// The memory page in Settings.
final class RAMSettingsPage: NSView {

    private var shown: Set<MenuBarStyle>
    private let styles = RAMModule().menuBarStyles

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "RAM"))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        let section = Controls.section(localized("Memory"), symbol: "memorychip.fill", tint: .systemGreen, [
            Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "RAM")),
            Controls.row(localized("Chart history"), Controls.choice(
                [("1 minute", "60"), ("2 minutes", "120"), ("5 minutes", "300")],
                selected: "\(RAMSettings.historyLength)") { value in
                    RAMSettings.historyLength = Int(value) ?? 120
                }),
            Controls.row(localized("Top processes"), Controls.choice(
                [("None", "0"), ("5", "5"), ("8", "8"), ("12", "12")],
                selected: "\(RAMSettings.processCount)") { value in
                    RAMSettings.processCount = Int(value) ?? 8
                })
        ])

        let shapes = Controls.section(
            localized("Menu bar"), symbol: "menubar.rectangle", tint: .systemBlue,
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.shapes(self.styles, shown: self.shown, label: RAMModule().menuBarLabel,
                             value: "42%", ) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "RAM")
            }])

        let alerts = Controls.section(localized("Notify me when"), symbol: "bell.badge.fill",
                                      tint: .systemRed,
            RAMThreshold.allCases.filter { $0.isAvailable }.map { threshold in
                Controls.row(threshold.title, control(for: threshold))
            })

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

    /// Pressure is a level, not a number to step through, so it gets a
    /// choice of the kernel's own words instead of a stepper.
    private func control(for threshold: RAMThreshold) -> NSView {
        guard threshold.scale == .pressureLevel else {
            return Controls.threshold(on: threshold.isWatched,
                                      value: threshold.level,
                                      suffix: threshold.scale.suffix,
                                      range: threshold.range,
                                      step: threshold.step) { on, level in
                threshold.isWatched = on
                threshold.level = level
            }
        }
        let choice = Controls.choice([("Warning", "2"), ("Critical", "4")],
                                     selected: "\(threshold.level)") { value in
            threshold.level = Int(value) ?? 2
        }
        let toggle = Controls.toggle(threshold.isWatched) { on in
            threshold.isWatched = on
            choice.isEnabled = on
        }
        choice.isEnabled = threshold.isWatched

        let row = NSStackView(views: [choice, toggle])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
