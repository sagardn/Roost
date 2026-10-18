import AppKit

/// What the application shell needs from a monitoring module.
///
/// Derived from what the six shell files actually call, not from Kit's
/// `Module` — which carries readers, widget enumeration, notification
/// wrappers, preview builders, portal construction, a logger and a pause
/// state, almost none of which the shell touches. The shell wants a name, a
/// switch, three views and a lifecycle. That is this.
///
/// Kit's modules conform through an extension until they are gone, so each
/// consumer migrates to this protocol on its own and the app is never half
/// converted. The conformance is scaffolding and is deleted with the modules.
protocol RoostModule: AnyObject {

    // MARK: Identity

    /// Shown in the sidebar, the settings header and the menu bar autosave
    /// name. Also the key prefix every preference for this module uses, so it
    /// must stay stable across releases.
    var moduleName: String { get }

    /// False when the hardware or OS cannot supply this reading — no battery
    /// in a desktop, no Bluetooth radio. An unavailable module is shown
    /// switched off and cannot be turned on.
    var isAvailable: Bool { get }

    /// What a fresh install should do with it.
    var isOnByDefault: Bool { get }

    /// Whether a settings preview is worth offering for this module.
    var hasPreview: Bool { get }

    // MARK: Switch

    /// Whether the user has it on. Setting it is the switch being flipped:
    /// the module starts or stops its own sampling and menu bar item.
    var isEnabled: Bool { get set }

    // MARK: Lifecycle

    /// Called once at launch, for every module, enabled or not. A module
    /// decides for itself whether to start sampling.
    func start()

    /// Called at quit. Release status items, invalidate timers, close files.
    func stop()

    /// The key combination that opens this module's popup, as virtual key
    /// codes, or empty for none.
    ///
    /// The shell needs this to decide whether to arm a global keyboard
    /// monitor at all -- asking macOS for one is asking to be offered Input
    /// Monitoring, and almost nobody sets a shortcut.
    var popupShortcut: [UInt16] { get }

    // MARK: Views

    /// The window of the module's menu bar item, if it is showing one.
    ///
    /// A window rather than the status item: the only thing the shell does
    /// with it is anchor a popup underneath, and asking for the item would
    /// have forced every implementation to own an NSStatusItem even when its
    /// reading is drawn inside a combined one.
    var menuBarWindow: NSWindow? { get }

    /// The tile this module contributes to the Dashboard, or nil for none.
    func makePortal() -> NSView?

    /// The module's page in Settings, or nil if it has no settings.
    func makeSettingsPage() -> NSView?

    // MARK: Menu bar

    /// Where this module sits when every reading shares one item.
    ///
    /// The position the user dragged it to, under the key Kit stored it
    /// under, so a menu bar someone has arranged stays arranged.
    var combinedPosition: Int { get }

    /// How this module's reading is drawn.
    ///
    /// Asked once per module and remembered by `MonitorBar`, because the
    /// answer owns a view and a popup and those should outlive a rebuild of
    /// the menu bar.
    func menuBarPresence() -> MenuBarPresence
}

/// How a module's reading reaches the menu bar.
///
/// Two ways, because there are two kinds of module while Kit is being
/// replaced, and the menu bar must not care which it is holding.
enum MenuBarPresence {
    /// The module draws its own reading, into a view it creates and keeps
    /// sized. Kit's modules do: their widgets are theirs.
    case segment(MenuBarSegment)

    /// Roost draws the reading, from what the module already tells its
    /// popup. Nothing further is needed -- a title and a `menuBarContent()`
    /// is a menu bar reading.
    case reading(PopupContent)

    /// Nothing in the menu bar.
    case none
}

extension RoostModule {
    var combinedPosition: Int {
        Preferences.shared.int("\(moduleName)_position", default: 0)
    }

    func menuBarPresence() -> MenuBarPresence { .none }
}

/// A module that already describes itself to a popup needs to say nothing
/// more to be in the menu bar.
extension RoostModule where Self: PopupContent {
    func menuBarPresence() -> MenuBarPresence { .reading(self) }
}

/// The modules the application runs, in the order they appear.
///
/// Replaces the global `var modules: [Module]` that AppDelegate declared. A
/// registry rather than a bare array so registration order, lookup and the
/// enabled subset all have one home, and so a module can be registered without
/// the registry knowing which framework it came from.
final class ModuleRegistry {

    static let shared = ModuleRegistry()

    private(set) var all: [any RoostModule] = []

    private init() {}

    /// Order is the menu bar order and the sidebar order, so it is the
    /// registration order and nothing re-sorts it.
    func register(_ modules: [any RoostModule]) {
        all = modules
    }

    func named(_ name: String) -> (any RoostModule)? {
        all.first { $0.moduleName == name }
    }

    var enabled: [any RoostModule] {
        all.filter { $0.isEnabled && $0.isAvailable }
    }

    func startAll() {
        // Reversed, because each module inserts its menu bar item at the
        // leading edge as it starts: registering in display order and starting
        // in reverse is what puts them on screen in the order declared.
        all.reversed().forEach { $0.start() }
    }

    func stopAll() {
        all.forEach { $0.stop() }
    }
}
