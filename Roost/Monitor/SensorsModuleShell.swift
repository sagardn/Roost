import AppKit

/// What the application shell needs of the sensors module.
extension SensorsModule: RoostModule {

    var moduleName: String { "Sensors" }

    /// A Mac with no sensor service and no SMC is not one this runs on, but
    /// a module that claims to be available and then shows a dash is worse
    /// than one that says it has nothing.
    var isAvailable: Bool { SensorsSettings.hasSensors }

    /// On, as the module it replaces was.
    var isOnByDefault: Bool { true }

    var hasPreview: Bool { false }

    var isEnabled: Bool {
        get { SensorsSettings.isEnabled }
        set {
            guard newValue != SensorsSettings.isEnabled else { return }
            SensorsSettings.isEnabled = newValue
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

    var popupShortcut: [UInt16] { SensorsSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { SensorsSettingsPage() }
}

/// Sensors' own preferences, under the keys the module it replaces used.
enum SensorsSettings {
    private static let prefs = Preferences.shared

    static var isEnabled: Bool {
        get { prefs.bool("Sensors_state", default: true) }
        set { prefs.set("Sensors_state", newValue) }
    }

    /// Whether the HID sensor service is read as well as the SMC.
    /// `Sensors_hid`, the key the old module used for the same switch.
    static var includesHID: Bool {
        get { prefs.bool("Sensors_hid", default: true) }
        set { prefs.set("Sensors_hid", newValue) }
    }

    /// The sensor the menu bar figure is about, by id. Empty means the
    /// hottest temperature, whichever that turns out to be.
    ///
    /// `Sensors_sensor`, the key the old module used.
    static var watched: String? {
        get {
            let stored = prefs.string("Sensors_sensor", default: "")
            return stored.isEmpty ? nil : stored
        }
        set { prefs.set("Sensors_sensor", newValue ?? "") }
    }

    /// How many ticks between full reads. Reading everything walks the whole
    /// SMC key table, which is a thousand round trips, so this is seconds
    /// rather than every tick.
    ///
    /// `Sensors_updateInterval`, which the old module stored in seconds.
    static var interval: Int {
        get { min(max(prefs.int("Sensors_updateInterval", default: 3), 1), 60) }
        set { prefs.set("Sensors_updateInterval", min(max(newValue, 1), 60)) }
    }

    /// Whether the keys nobody has a name for are listed at all.
    ///
    /// `Sensors_unknown`, the key and the default the old module used. A Mac
    /// answers with over two hundred sensors and most are keys like `Tp09`
    /// that mean nothing without the firmware's own documentation. Off, they
    /// are one switch away; on, the list is everything.
    static var showsUnnamed: Bool {
        get { prefs.bool("Sensors_unknown", default: false) }
        set { prefs.set("Sensors_unknown", newValue) }
    }

    /// Whether a sensor has a name somebody could act on.
    static func isNamed(_ id: String) -> Bool {
        SensorReadings.names[id] != nil || id.hasPrefix("hid:")
    }

    /// Whether a sensor appears in the popup list.
    ///
    /// `sensor_<id>`, the key the old module used -- note the lowercase
    /// prefix, which is not the module's name. Kept as it was so a Mac with
    /// sensors picked keeps them picked.
    static func isShown(_ id: String) -> Bool {
        guard isNamed(id) || showsUnnamed else { return false }
        return prefs.bool("sensor_\(id)", default: true)
    }

    static func setShown(_ id: String, _ shown: Bool) {
        prefs.set("sensor_\(id)", shown)
    }

    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "Sensors_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }

    /// Whether this Mac publishes any sensor at all, asked once.
    ///
    /// The cheap question, not the expensive one: whether the HID service
    /// answers, or the SMC connection opens. Reading every sensor to find
    /// out costs 0.15s and this runs before the first window is on screen.
    static let hasSensors: Bool = Temperature.isAvailable || SMCKit.shared.value("#KEY") != nil
}

/// The sensors page in Settings.
final class SensorsSettingsPage: NSView {

    private var shown: Set<MenuBarStyle>
    private let styles = SensorsModule().menuBarStyles
    private let titles: (MenuBarStyle) -> String = { SensorsModule().title(for: $0) }

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "Sensors",
                                              default: SensorsModule().defaultMenuBarStyles))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        let sensors = SensorReadings.all(includingHID: SensorsSettings.includesHID)

        // Named sensors first: on a Mac answering with two hundred keys, a
        // picker listing every one of them is not a picker.
        let choices: [(String, String)] = [(localized("Hottest temperature"), "")]
            + sensors.filter { SensorReadings.names[$0.id] != nil || $0.id.hasPrefix("hid:") }
                .map { ($0.name, $0.id) }

        let general = Controls.section(localized("Sensors"), symbol: "thermometer.medium", tint: .systemRed, [
            Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "Sensors")),
            Controls.row(localized("Watch"), Controls.choice(choices,
                                                  selected: SensorsSettings.watched ?? "") { id in
                SensorsSettings.watched = id.isEmpty ? nil : id
            }),
            Controls.row(localized("Read the HID sensors"),
                         Controls.toggle(SensorsSettings.includesHID) { on in
                             SensorsSettings.includesHID = on
                         }),
            Controls.row(localized("Read every"), Controls.choice(
                [("1 second", "1"), ("3 seconds", "3"), ("10 seconds", "10")],
                selected: "\(SensorsSettings.interval)") { value in
                    SensorsSettings.interval = Int(value) ?? 3
                }),
            Controls.row(localized("List the keys nobody has named"),
                         Controls.toggle(SensorsSettings.showsUnnamed) { on in
                             SensorsSettings.showsUnnamed = on
                         })
        ])

        let shapes = Controls.section(
            localized("Menu bar"), symbol: "menubar.rectangle", tint: .systemBlue,
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.shapes(self.styles, shown: self.shown, label: SensorsModule().menuBarLabel,
                             value: "62°",
                            title: self.titles, ) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "Sensors")
            }])

        // One switch per sensor, grouped by family -- but only the ones with
        // names unless the switch above says otherwise. Building a row is
        // two views and a constraint set, and the first version of this page
        // built two hundred and twenty-nine of them: measured at nine
        // seconds to open, which is not a settings page, it is a hang.
        let listed = sensors.filter { SensorsSettings.isNamed($0.id)
                                      || SensorsSettings.showsUnnamed }
        var listRows: [NSView] = []
        for family in SensorReadings.Family.allCases {
            let group = listed.filter { $0.family == family }
            guard !group.isEmpty else { continue }
            listRows.append(Controls.subheading(family.rawValue))
            // The reading beside its switch, not run into its name: "Battery
            // 34°" as one string put the figure wherever the name ended.
            listRows += group.map { sensor in
                Controls.row(sensor.name, Controls.group([
                    Controls.label(sensor.formatted),
                    Controls.toggle(SensorsSettings.isShown(sensor.id)) { on in
                        SensorsSettings.setShown(sensor.id, on)
                    }
                ]))
            }
        }
        let list = Controls.section(localized("Show in the popup"), symbol: "list.bullet",
                                    tint: .systemGray, listRows)

        let column = NSStackView(views: [general, shapes, list])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 44, left: 18, bottom: 18, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor)
        ])
        for section in column.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: column.widthAnchor,
                                           constant: -36).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
