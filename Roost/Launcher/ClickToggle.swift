/// What one click on an app in the launcher does: the Windows taskbar's rule,
/// on macOS's windows.
///
/// not running                    -> launch it
/// hidden (⌘H)                    -> unhide it
/// in front, windows on screen    -> minimize all of them
/// in front, all minimized        -> restore
/// behind, windows on screen      -> bring it to the front
/// behind, all minimized          -> restore and bring it to the front
/// running with no window at all  -> ask it for one, as the Dock does
///
/// Kept apart from `WindowControl`, which reads the state over the
/// Accessibility API and carries the answer out, so that every row of that
/// table can be tested without a live app -- the cases that matter most,
/// minimised and full screen, are the slowest to set up by hand.
enum ClickToggle {

    struct Window: Equatable {
        var isMinimized = false
        var isFullScreen = false
        /// Whether AXMinimized can be set. Some panels and utility windows
        /// refuse, and setting it then fails without a word.
        var canMinimize = true
        var isMain = false
        /// Minimised by Roost's last click on this app, so the next click
        /// brings back exactly these.
        var minimizedByRoost = false
    }

    struct Snapshot {
        var isRunning = false
        var isHidden = false
        /// The app the person was in. Not simply the frontmost app at the
        /// moment of the click: the launcher panel takes focus while it is
        /// open, so the caller passes the app that was in front before it.
        var isActive = false
        var launchOnly = false
        var windows: [Window] = []
    }

    enum Action: Equatable {
        case launch
        case unhide
        case raise
        /// Running with no window: the Dock's reopen, which makes most apps
        /// open one. Activating alone shows nothing at all, which reads as
        /// the click doing nothing.
        case reopen
        /// Un-minimise these windows (by index) and bring the app forward.
        case restore([Int])
        /// Minimise these windows (by index).
        case minimize([Int])
        /// In front with windows showing, none of which can be minimised:
        /// hiding the app is the nearest thing that still gets it out of
        /// the way.
        case hide
        /// macOS will not minimise a full-screen window, and hiding the app
        /// instead tears down its Space -- see `WindowControl.toggle`.
        case refuseFullScreen
    }

    static func decide(_ app: Snapshot) -> Action {
        guard app.isRunning else { return .launch }
        // Launchpad and its kind: a launcher shows itself and dismisses
        // itself, and has no window of its own to minimise.
        if app.launchOnly { return .raise }
        if app.isHidden { return .unhide }

        let onScreen = app.windows.indices.filter { !app.windows[$0].isMinimized }
        let minimized = app.windows.indices.filter { app.windows[$0].isMinimized }

        guard !onScreen.isEmpty else {
            return minimized.isEmpty ? .reopen : .restore(restoreTargets(app.windows, minimized))
        }
        guard app.isActive else { return .raise }

        // The window being looked at is full screen: there is nothing
        // honest to do but say so. Minimising the app's other windows would
        // leave the full-screen one in front and look like nothing happened.
        if onScreen.contains(where: { app.windows[$0].isMain && app.windows[$0].isFullScreen }) {
            return .refuseFullScreen
        }
        let targets = onScreen.filter { app.windows[$0].canMinimize && !app.windows[$0].isFullScreen }
        if !targets.isEmpty { return .minimize(targets) }
        return onScreen.contains { app.windows[$0].isFullScreen } ? .refuseFullScreen : .hide
    }

    /// What a restore brings back: the windows Roost minimised last time, if
    /// any are still down; otherwise one. Restoring every minimised window
    /// would bring back a Dock full of Finder windows put away by hand, one
    /// at a time, over a week.
    private static func restoreTargets(_ windows: [Window], _ minimized: [Int]) -> [Int] {
        let ours = minimized.filter { windows[$0].minimizedByRoost }
        return ours.isEmpty ? Array(minimized.prefix(1)) : ours
    }
}
