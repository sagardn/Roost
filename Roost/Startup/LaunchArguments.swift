import Foundation

/// The arguments Roost acts on at startup.
///
/// Parsed into a value first, then applied, rather than read out of
/// `CommandLine.arguments` at each use site. Two reasons, and the second is
/// the one that matters: a parser with no side effects can be checked against
/// argument lists written down, and an argument that *does* something at
/// startup -- resetting the settings store, rewriting the login item -- is
/// worth checking before it runs rather than after.
///
/// The diagnostic arguments are here too. They exist because most of this app
/// cannot be checked by hand: opening a popup needs a click on a menu bar
/// item, which needs UI-scripting permission a CI runner does not have, and a
/// pane with a broken constraint looks exactly like a correct one in every
/// assertion that does not draw it.
struct LaunchArguments: Equatable {

    /// `--popup <name> [seconds]`
    struct PopupRequest: Equatable {
        let name: String
        /// The wait before opening, because a popup opened before its reader
        /// has sampled anything shows dashes.
        let delay: TimeInterval
    }

    /// `--render <subject> <path>`
    struct RenderRequest: Equatable {
        /// `settings:<Module>`, `setup:<n>` or `window:<page>`.
        let subject: String
        let path: String
    }

    /// Point the login item at this copy of the app.
    var registerLoginItem = false
    /// Remove the login item registration owned by this copy.
    ///
    /// Both exist because only the registered bundle can unregister itself,
    /// so a login item pointing at a copy that has been moved or deleted
    /// cannot be repaired from the copy that is now in `/Applications`.
    var unregisterLoginItem = false

    /// Wipe the settings store.
    var reset = false

    /// Modules to switch off, lower-cased for comparison.
    ///
    /// Lower-cased at parse time rather than at each comparison: the names
    /// arrive from a human typing on a command line, and the comparison
    /// happening in one place is what stops half of it being
    /// case-insensitive.
    var disabledModules: [String] = []

    var popup: PopupRequest?
    /// `--menu-bar a,b,c` — the steps, lower-cased, in order.
    var menuBarSteps: [String] = []
    var render: RenderRequest?

    /// The default wait for `--popup`, in seconds.
    static let defaultPopupDelay: TimeInterval = 6

    static func parse(_ argv: [String]) -> LaunchArguments {
        var parsed = LaunchArguments()

        parsed.registerLoginItem = argv.contains("--register-login-item")
        parsed.unregisterLoginItem = argv.contains("--unregister-login-item")
        parsed.reset = argv.contains("--reset")

        if let list = value(after: "--disable", in: argv) {
            parsed.disabledModules = list
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        if let name = value(after: "--popup", in: argv) {
            // The seconds are optional, so what follows the name is only a
            // delay if it parses as a number. `--popup CPU --render ...` and
            // `--popup CPU` must both mean the default wait rather than
            // swallowing the next argument.
            let index = argv.firstIndex(of: "--popup")!
            let next = argv.indices.contains(index + 2) ? argv[index + 2] : nil
            parsed.popup = PopupRequest(
                name: name,
                delay: next.flatMap(Double.init) ?? defaultPopupDelay)
        }

        if let steps = value(after: "--menu-bar", in: argv) {
            parsed.menuBarSteps = steps.lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        // Two values, and no default for either: rendering to a path nobody
        // asked for would write a file somewhere unexpected.
        if let subject = value(after: "--render", in: argv) {
            let index = argv.firstIndex(of: "--render")!
            if argv.indices.contains(index + 2), !argv[index + 2].hasPrefix("--") {
                parsed.render = RenderRequest(subject: subject, path: argv[index + 2])
            }
        }

        return parsed
    }

    /// The argument following `flag`, or nil.
    ///
    /// nil when the flag is last on the line, which is the shape a typo takes
    /// (`--disable` with the module name forgotten). Also nil when what
    /// follows is itself a flag: `--disable --reset` means somebody forgot the
    /// list, and treating "--reset" as a module name would silently consume
    /// the next argument instead of running it.
    private static func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag),
              argv.indices.contains(index + 1) else { return nil }
        let next = argv[index + 1]
        return next.hasPrefix("--") ? nil : next
    }
}
