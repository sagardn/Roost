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
    /// One of the tools that look after the Mac rather than measure it:
    /// the Check-up, the cleanup and file finders, the uninstaller, the
    /// protections. Each is a page of its own, grouped in the sidebar by the
    /// job somebody came to do.
    case tool(Tool)
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

    /// The tools, in sidebar order. Their raw value is the page's name,
    /// which is what a notification addresses it by.
    ///
    /// They were two hub pages, Free up space and Uninstall apps, each a list
    /// of buttons opening a window of its own -- five windows to keep track
    /// of, and nothing in the sidebar saying a duplicate finder existed
    /// until its hub was opened. One page per tool, in the window that is
    /// already open, is how every Mac maintenance app is laid out, and the
    /// sidebar becomes the table of contents.
    enum Tool: String, CaseIterable {
        case checkUp = "Check-up"
        case storage = "Storage"
        case largeFiles = "Large files"
        case duplicates = "Duplicates"
        case spaceMap = "Space map"
        case aiTools = "AI tools"
        case uninstaller = "Uninstaller"
        case backgroundItems = "Background items"
        // Not "Protection": that is the heading it sits under, and a
        // heading over one row of the same name read as a stutter.
        case protection = "macOS protections"

        /// The sidebar section it sits under. The Check-up has none: it
        /// runs the others, so it sits above them with the Overview.
        ///
        /// Files was a heading of its own, and the line between it and
        /// Cleanup was not one anybody could draw: a large file and a
        /// duplicate are what a person cleans up. AI tools stays under
        /// Cleanup rather than going to a "Tools" heading -- what it does is
        /// clear out the sessions AI assistants leave behind, which is
        /// cleaning, whatever its name suggests.
        var group: Group? {
            switch self {
            case .checkUp:
                return nil
            case .storage, .largeFiles, .duplicates, .spaceMap:
                return .cleanup
            case .uninstaller, .backgroundItems:
                return .applications
            case .protection:
                return .protection
            // Under Tools, beside the launcher, not under Cleanup. It reads
            // the AI apps' own folders rather than the disk at large, and
            // among Storage, Large files, Duplicates and Space map -- four
            // views of the same disk -- it was the one row that was not.
            case .aiTools:
                return .tools
            }
        }
    }

    enum Group: String, CaseIterable {
        case cleanup = "Cleanup"
        case applications = "Applications"
        case protection = "Protection"
        /// The AI tools page and, appended by the sidebar, Search &
        /// switcher -- which is not a `Tool` because it is a settings page,
        /// not a scan. A heading of its own for one row read as an orphan.
        case tools = "Tools"
    }

    /// Names the pages had before they were split, still answered. The
    /// Disk popup and the Overview ask for "Free up space" when the disk is
    /// full, and the Check-up is where that should land: it is the page that
    /// says what is worth doing about it.
    static let aliases: [String: Tool] = [
        "Free up space": .checkUp,
        "Uninstall apps": .uninstaller
    ]

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
        if let tool = Tool(rawValue: name) ?? aliases[name] { return .tool(tool) }
        switch name {
        case "Dashboard":      return .dashboard
        case "Settings":       return .appSettings
        case "Search & switcher": return .launcher
        default:               return nil
        }
    }

    /// The name this page is known by, which is also its sidebar selection.
    var name: String {
        switch self {
        case .dashboard:        return "Dashboard"
        case .appSettings:      return "Settings"
        case .tool(let tool):   return tool.rawValue
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
