import Foundation

/// Which page the settings window is showing.
///
/// Separated from the window so the name-to-page mapping can be checked
/// against names written down. It is a mapping with real edge cases in it --
/// a name nothing answers to, a module whose name collides with a built-in
/// page, and an alias the menu bar uses for something that is not a page at
/// all -- and the window cannot be instantiated in a test script.
enum SettingsSelection: Equatable {

    case dashboard
    case appSettings
    /// The Free up space page. Not a module: it configures nothing and has
    /// no menu bar item, but it is a page of its own because it is about the
    /// Mac rather than about any one reading.
    case cleanup
    /// The launcher's page: its keys, how the search and switcher behave,
    /// and the app list. Its own page rather than a section of Settings,
    /// because it is half of what Roost is, and it was the fifth section
    /// down a page about the menu bar.
    case launcher
    /// A module's own settings page, by module name.
    case module(String)

    /// The alias the menu bar uses when every reading shares one status item.
    ///
    /// It is not a page: there is no "Combined modules" settings page to
    /// open, and what somebody clicking its gear wants is the page that
    /// controls the combined item, which is the dashboard.
    static let combinedAlias = "Combined modules"

    /// A name from anywhere in the app, resolved to a page.
    ///
    /// Modules are matched first, deliberately. A module named "Dashboard"
    /// would shadow the built-in dashboard page, and that is the right way
    /// round: the module is a real thing with a real page, and the built-in
    /// names are the fallback.
    ///
    /// nil for a name nothing answers to. The window then leaves what it is
    /// showing alone, rather than blanking itself for a name that was
    /// probably a typo in a notification.
    static func resolve(_ name: String, moduleNames: [String]) -> SettingsSelection? {
        // Resolved here rather than at one of the two call sites, which is
        // where it used to be. The window is reached both by `open(module:)`
        // and by an .openModuleSettings notification, only the first of them
        // translated the alias, and so the same name did different things
        // depending on which way in it came.
        let name = name == combinedAlias ? "Dashboard" : name

        if moduleNames.contains(name) { return .module(name) }
        switch name {
        case "Dashboard":      return .dashboard
        case "Settings":       return .appSettings
        case "Free up space":  return .cleanup
        case "Search & switcher": return .launcher
        default:               return nil
        }
    }

    /// The name this page is known by, which is also its sidebar selection.
    var name: String {
        switch self {
        case .dashboard:        return "Dashboard"
        case .appSettings:      return "Settings"
        case .cleanup:          return "Free up space"
        case .launcher:         return "Search & switcher"
        case .module(let name): return name
        }
    }

    /// Whether a module's own window is what is being configured.
    ///
    /// Carried by `.openWindow` so a module can bring its menu bar item
    /// forward while its page is open and put it back afterwards.
    var isModule: Bool {
        if case .module = self { return true }
        return false
    }
}
