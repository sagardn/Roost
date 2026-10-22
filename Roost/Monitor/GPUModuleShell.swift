import AppKit

/// What the application shell needs of the graphics module.
extension GPUModule: RoostModule {

    var moduleName: String { "GPU" }

    /// False on a Mac where no accelerator answers at all, which is not a
    /// machine that exists -- but a module that claims to be available and
    /// then shows a dash is worse than one that says it has nothing.
    ///
    /// Answered once. This is read every second by the menu bar's tick and
    /// cost 1.58 ms a read, walking the IORegistry for accelerators that do
    /// not come and go: a Mac does not grow a GPU while it is running, and
    /// the one case that could -- an eGPU unplugged -- leaves the module
    /// showing a dash, which is what it would show anyway.
    var isAvailable: Bool { Self.hasAccelerator }

    private static let hasAccelerator: Bool = !GPUStats.read().isEmpty

    /// Off, as the module it replaces was. A graphics figure is a specialist
    /// reading, and the menu bar is finite.
    var isOnByDefault: Bool { false }

    var hasPreview: Bool { false }

    var isEnabled: Bool {
        get { GPUSettings.isEnabled }
        set {
            guard newValue != GPUSettings.isEnabled else { return }
            GPUSettings.isEnabled = newValue
            newValue ? MonitorBar.shared.show(self) : MonitorBar.shared.hide(moduleName)
        }
    }

    func start() {
        guard isEnabled, isAvailable else { return }
        MonitorBar.shared.show(self)
    }

    func stop() {
        willStop()
        MonitorBar.shared.hide(moduleName)
    }

    var popupShortcut: [UInt16] { GPUSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { GPUSettingsPage() }
}

/// Graphics' own preferences, under the keys the module it replaces used.
enum GPUSettings {
    private static let prefs = Preferences.shared

    /// `GPU_state`, and the default is off -- which is what the old module's
    /// config said too.
    static var isEnabled: Bool {
        get { prefs.bool("GPU_state", default: false) }
        set { prefs.set("GPU_state", newValue) }
    }

    static var historyLength: Int {
        get { prefs.int("GPU_historyLength", default: 120) }
        set { prefs.set("GPU_historyLength", newValue) }
    }

    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "GPU_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }
}

/// The graphics page in Settings.
final class GPUSettingsPage: NSView {

    private var shown: Set<MenuBarStyle>
    private let styles = GPUModule().menuBarStyles

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "GPU"))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        // Grouped by where each setting shows -- the menu bar item, the popup
        // it opens, then notifications -- rather than under a heading that
        // repeated the page title. The shortcut opens the popup from the
        // keyboard, so it sits with the item it stands in for a click on.
        let shapes = Controls.section(
            localized("Menu bar"),
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "GPU")),
             Controls.shapes(self.styles, shown: self.shown, label: GPUModule().menuBarLabel,
                             value: "42%", ) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "GPU")
            }])

        let popup = Controls.section(localized("Show in the popup"), [
            Controls.row(localized("Chart history"), Controls.choice(
                [("1 minute", "60"), ("2 minutes", "120"), ("5 minutes", "300")],
                selected: "\(GPUSettings.historyLength)") { value in
                    GPUSettings.historyLength = Int(value) ?? 120
                })
        ])

        let alerts = Controls.section(localized("Notify me when"),
            GPUThreshold.allCases.map { threshold in
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
