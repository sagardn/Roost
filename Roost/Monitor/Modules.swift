import AppKit

/// What a module hands to the popup window.
///
/// The window knows nothing about networks or processors: it draws a header,
/// scrolls whatever view it is given, and tells the module when it is on
/// screen. Everything module-specific lives behind this.
///
/// This is the contract the independent monitor is being built against --
/// deliberately unrelated to Kit's `Module_p`, which is upstream's and goes
/// when Kit does.
protocol PopupContent: AnyObject {
    /// Shown in the popup header, and used as the settings key prefix.
    var title: String { get }

    /// Built once, the first time the popup opens, and kept afterwards --
    /// rebuilding it on every open would throw away chart history.
    func makeView() -> NSView

    /// Called as the popup opens and closes. A module should start whatever
    /// sampling only it needs here, and stop it again on hide: nothing
    /// expensive should run while nobody is looking.
    func willShow()
    func didHide()

    /// Called on the shared tick, only while visible.
    func refresh()

    /// What the module's own menu bar item says. Short: the bar is narrow.
    var menuBarLabel: String { get }

    /// Samples whatever the menu bar needs and returns it.
    ///
    /// This is the module's sampling tick and runs whether or not the popup
    /// is open -- a menu bar reading that only moved while you were looking
    /// at the popup would be useless. It must stay cheap: counters and
    /// syscalls, never a subprocess. `refresh()` renders from whatever this
    /// last stored, and does the expensive popup-only work itself.
    func menuBarContent() -> MenuBarReading?

    /// A view to drop down from the gear. nil, which every module returns
    /// today, sends the gear to the module's page in the Settings window.
    func settingsView() -> NSView?

    /// The shapes to draw in the menu bar when the user has not chosen.
    ///
    /// A module says what suits it: a figure for a percentage, and for
    /// network nothing at all, since its pair of rates is not one of the six.
    var defaultMenuBarStyles: [MenuBarStyle] { get }

    /// The shapes this module can actually fill, for its settings page.
    ///
    /// Not every shape suits every reading: only a module with two figures
    /// worth stacking can draw a pair, and offering a switch for a shape that
    /// would come out blank is worse than not offering it.
    var menuBarStyles: [MenuBarStyle] { get }
}

extension PopupContent {
    var menuBarLabel: String { String(title.prefix(3)).uppercased() }
    var defaultMenuBarStyles: [MenuBarStyle] { [.mini] }
    /// The six every module shares. A module with a pair or a pair of
    /// series says so by overriding this.
    var menuBarStyles: [MenuBarStyle] {
        MenuBarStyle.allCases.filter { !MenuBarStyle.special.contains($0) }
    }
    func menuBarContent() -> MenuBarReading? { nil }
    func willShow() {}
    func didHide() {}
    func settingsView() -> NSView? { nil }
}

/// The modules the independent monitor offers so far, in menu bar order.
///
/// A plain array rather than a registration mechanism: there will be under
/// ten of them, they are all known at compile time, and the order matters.
enum NativeModules {
    /// Empty, and that is the point: every module Roost draws is now a
    /// registered module in its own right rather than a preview sitting
    /// beside the one it duplicates. `allModules` is the list that matters.
    /// This stays for the next one, which will spend a few commits here
    /// before it takes a registry entry over.
    static let all: [PopupContent] = []

    static func named(_ title: String) -> PopupContent? {
        all.first { $0.title == title }
    }
}

/// "Show in the menu bar", the first row of a module's page: the module's
/// on/off switch, now that the sidebar rows are only for going places.
///
/// A view of its own rather than `Controls.toggle` with a closure, because it
/// has to follow the module as well as change it -- the sidebar row's context
/// menu can switch the module while this page is open -- and the observer
/// that does that has to go when the page does.
final class ModuleSwitch: NSView {

    private let name: String
    private let control: NSSwitch
    private var observer: NSObjectProtocol?

    init(module name: String) {
        self.name = name
        self.control = Controls.toggle(ModuleRegistry.shared.named(name)?.isEnabled ?? false) { on in
            SettingsModel.setModule(name, enabled: on)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(localized("Show in the menu bar"))
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        observer = NotificationCenter.default.addObserver(
            forName: .toggleModule, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["module"] as? String == self.name,
                  let on = note.userInfo?["state"] as? Bool else { return }
            self.control.state = on ? .on : .off
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The row, as every module page opens its Menu bar section with it.
    static func row(_ name: String) -> NSView {
        Controls.row(localized("Show in the menu bar"), ModuleSwitch(module: name))
    }
}
