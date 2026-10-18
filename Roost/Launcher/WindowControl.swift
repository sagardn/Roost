import AppKit
import ApplicationServices

/// What a menu row should show, and what a click should do.
enum AppState {
    case notRunning
    case noWindow      // menu-bar-only app: nothing to minimize
    case visible       // has a window on screen
    case minimized     // window minimized, or app hidden
    case fullScreen    // macOS refuses to minimize these
}

enum WindowControl {

    // MARK: - Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt; returns current trust state.
    ///
    /// Private on purpose: calling this is what puts the macOS dialog on
    /// screen, and the only places that should is `ensureTrusted(for:)` --
    /// once -- and the button in Settings. It used to be called on every
    /// launch, which is why Roost asked for permission at every login.
    @discardableResult
    private static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Set once the dialog has been shown, so it is shown at most once.
    private static let askedKey = "accessibilityAsked"
    /// Set once the grant has been seen in force, so "never set up" can be
    /// told apart from "was working and stopped".
    private static let hadTrustKey = "accessibilityWasGranted"

    /// True when Accessibility was granted at some point and is not in force
    /// now. That is what an update does: Roost is signed ad hoc, so every
    /// build has a different code signature and macOS treats the new one as a
    /// different app than the one that was allowed. Worth its own sentence --
    /// "grant this" is the wrong instruction when the entry is already there
    /// and merely stale.
    static var wasRevoked: Bool {
        !isTrusted && UserDefaults.standard.bool(forKey: hadTrustKey)
    }

    /// Call before anything that needs Accessibility; returns whether to go
    /// ahead.
    ///
    /// The system dialog appears the first time only. After that a HUD says
    /// what is missing, every time, because a key that silently does nothing
    /// is the thing being fixed here.
    @discardableResult
    static func ensureTrusted(for what: String) -> Bool {
        if isTrusted {
            UserDefaults.standard.set(true, forKey: hadTrustKey)
            return true
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: askedKey) {
            defaults.set(true, forKey: askedKey)
            requestAccessibility()
        } else if wasRevoked {
            Notify.show("Roost lost Accessibility in the update — re-add it in Settings",
                        symbol: "hand.raised.fill", for: 4)
        } else {
            Notify.show("\(what) needs Accessibility — Settings → Privacy & Security",
                        symbol: "hand.raised.fill", for: 4)
        }
        return false
    }

    /// The button in Settings. Always acts, because the user just clicked it.
    static func grantFromSettings() {
        if isTrusted {
            UserDefaults.standard.set(true, forKey: hadTrustKey)
            Notify.show("Accessibility is already granted", symbol: "checkmark.circle.fill")
            return
        }
        UserDefaults.standard.set(true, forKey: askedKey)
        requestAccessibility()
        openAccessibilitySettings()
    }

    /// Opens the Accessibility list itself rather than the top of Settings.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Small AX helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// An attribute's value as an `AXUIElement`, or nil if it is something
    /// else.
    ///
    /// The type is compared with `CFGetTypeID` and then cast unconditionally,
    /// which looks like the unsafe spelling and is the safe one. `as?` cannot
    /// do this job: the compiler rejects a conditional downcast to a
    /// CoreFoundation type with *"will always succeed"* and points at
    /// `CFGetTypeID` instead -- so `raw as? AXUIElement` would hand back a
    /// CFString as an element and fail later, somewhere else.
    ///
    /// One place, so the force cast sits beside the check that makes it
    /// sound rather than three times across the file.
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? Bool) ?? false
    }

    /// Finder publishes the desktop as an AXScrollArea alongside real windows.
    /// It cannot be minimized, so anything that is not a genuine AXWindow is
    /// ignored throughout.
    private static func isRealWindow(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXRoleAttribute as String) as? String) == (kAXWindowRole as String)
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement])?
            .filter(isRealWindow) ?? []
    }

    /// AXMainWindow is nil while an app's window is minimized, and for Finder
    /// it can be the desktop, so fall back to the app's real windows and
    /// prefer a minimized one -- that is the window a click wants to restore.
    private static func targetWindow(of app: AXUIElement) -> AXUIElement? {
        if let main = element(attribute(app, kAXMainWindowAttribute as String)),
           isRealWindow(main) {
            return main
        }
        let all = windows(of: app)
        return all.first(where: { bool($0, kAXMinimizedAttribute as String) }) ?? all.first
    }

    // MARK: - State

    static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // Each state() call is synchronous Accessibility IPC into another
    // process. Measured on this machine: ~183 ms to sweep 12 running apps,
    // with one slow app costing 29 ms on its own. The search panel rebuilds
    // on every keystroke, so typing six characters cost about a second of
    // blocked main thread. A short TTL removes all of that: window state
    // does not meaningfully change between keystrokes, and anything we
    // change ourselves invalidates its own entry immediately.
    //
    // Main-thread only, so a plain dictionary needs no locking.
    private static var stateCache: [String: (state: AppState, at: Date)] = [:]
    // 60, not the 5 it was. The short life was there because nothing told
    // the cache when an app's state changed, so it expired everything
    // constantly and a background timer refreshed it -- which cost about 4%
    // of a core for ever and, with nine apps running, provably could not keep
    // up: it refreshed 3 apps every 2 seconds, 1.5 a second, where nine apps
    // on a 5 second life need 1.8 a second. The panel opened cold anyway.
    //
    // The timer is gone and the events that actually change an app's state
    // invalidate it instead, below. A minute is then a backstop for the one
    // transition macOS does not announce -- a window minimised with its own
    // yellow button -- and costs nothing when nothing happens. Only the
    // state shown in a row depends on this; `toggle` reads the windows fresh
    // every time, so a stale entry can never make a click do the wrong thing.
    private static let stateTTL: TimeInterval = 60

    private static var stateObservers: [NSObjectProtocol] = []

    /// Drops an app's cached state when macOS says the app changed.
    ///
    /// Activation is already handled by `Recents`. These are the rest of the
    /// transitions that move an app between the `AppState` cases: hiding and
    /// unhiding are `.minimized`, launching and quitting are `.notRunning`.
    /// Each costs a dictionary write, against the Accessibility sweep per app
    /// that the timer here used to pay on a clock.
    static func observeAppChanges() {
        guard stateObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        stateObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                invalidateState(app?.bundleIdentifier)
            }
        }
    }

    static func invalidateState(_ bundleID: String?) {
        guard let bundleID else { return }
        stateCache[bundleID] = nil
    }

    static func invalidateAllStates() { stateCache.removeAll() }

    static func state(of bundleID: String) -> AppState {
        if let cached = stateCache[bundleID],
           Date().timeIntervalSince(cached.at) < stateTTL {
            return cached.state
        }
        let fresh = computeState(of: bundleID)
        stateCache[bundleID] = (fresh, Date())
        return fresh
    }

    /// An app's Accessibility element, with a bound on how long it may block.
    ///
    /// Every read of one of these is synchronous IPC into that app, and the
    /// default is to wait on it for as long as it takes. An app that is busy,
    /// beachballing or stopped in a debugger therefore freezes whichever of
    /// Roost's threads asked -- the main one, for the search panel's rows.
    /// A quarter second is far longer than a healthy app needs (the whole
    /// sweep of nine was about 260 ms) and short enough not to be felt.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func computeState(of bundleID: String) -> AppState {
        guard let running = runningApp(bundleID) else { return .notRunning }
        if running.isHidden { return .minimized }

        let axApp = appElement(running.processIdentifier)
        guard let window = targetWindow(of: axApp) else { return .noWindow }

        if bool(window, kAXMinimizedAttribute as String) { return .minimized }
        if bool(window, "AXFullScreen") { return .fullScreen }
        return .visible
    }

    // MARK: - Actions

    static func launch(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(window,
                                     kAXMinimizedAttribute as CFString,
                                     minimized as CFBoolean)
    }

    /// One click on an app in the launcher. What it does is
    /// `ClickToggle.decide`; this reads the app's state for it and carries
    /// the answer out.
    ///
    /// `activeApp` is the app the person was in when they reached for the
    /// launcher. The search panel takes focus while it is open, so by the
    /// time a row is picked the frontmost app is Roost, or whichever app
    /// macOS has got round to handing focus back to -- and comparing with
    /// that made "click the app you are in to minimise it" depend on a
    /// timer. Nil means ask macOS, which is right for a hotkey: nothing of
    /// Roost's was in front.
    static func toggle(_ entry: AppEntry, activeApp: String? = nil) {
        defer { invalidateState(entry.bundleID) }
        let running = runningApp(entry.bundleID)
        let active = activeApp ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var snapshot = ClickToggle.Snapshot(isRunning: running != nil,
                                            isHidden: running?.isHidden ?? false,
                                            isActive: active == entry.bundleID,
                                            launchOnly: entry.launchOnly)
        // Reading windows is the part that needs Accessibility, and only the
        // in-front case needs what it reads. Without the grant the list is
        // left empty, which decides as "no window" and so as the Dock's
        // reopen -- and the reopen event is itself the Dock's whole click:
        // the app raises, un-minimises or opens a window as it sees fit. The
        // person is asked for the grant only when a minimise is what they
        // wanted.
        var windows: [AXUIElement] = []
        if let running, !snapshot.isHidden, !entry.launchOnly, isTrusted {
            let axApp = appElement(running.processIdentifier)
            let main = element(attribute(axApp, kAXMainWindowAttribute as String))
            windows = self.windows(of: axApp)
            let remembered = minimizedByRoost[running.processIdentifier] ?? []
            snapshot.windows = windows.map { window in
                ClickToggle.Window(
                    isMinimized: bool(window, kAXMinimizedAttribute as String),
                    isFullScreen: bool(window, "AXFullScreen"),
                    canMinimize: isSettable(window, kAXMinimizedAttribute as String),
                    isMain: main.map { CFEqual($0, window) } ?? false,
                    minimizedByRoost: remembered.contains { CFEqual($0, window) })
            }
        }
        if running != nil, snapshot.isActive, !snapshot.isHidden, !entry.launchOnly,
           !ensureTrusted(for: "Minimising a window") { return }

        var action = ClickToggle.decide(snapshot)
        // With minimising switched off the launcher is a plain launcher: a
        // click brings an app forward and never puts it away. Applied here
        // rather than in `ClickToggle`, so the decision stays pure and the
        // preference governs the panel and the per-app hotkeys together.
        if !Prefs.clickMinimizes {
            switch action {
            case .minimize, .hide, .refuseFullScreen: action = .raise
            default: break
            }
        }

        switch action {
        case .launch:
            if !launch(entry.bundleID) { Notify.show("\(entry.name) is not installed") }
        case .unhide:
            running?.unhide()
            running.map(activate)
        case .raise:
            running.map(activate)
        case .reopen:
            // NSWorkspace sends a running app the reopen event, the same one
            // the Dock sends, and that is what makes it open a window.
            if !launch(entry.bundleID) { running.map(activate) }
        case .restore(let indices):
            for index in indices { setMinimized(windows[index], false) }
            if let running { minimizedByRoost[running.processIdentifier] = nil }
            running.map(activate)
        case .minimize(let indices):
            let down = indices.map { windows[$0] }
            for window in down { setMinimized(window, true) }
            if let running { minimizedByRoost[running.processIdentifier] = down }
        case .hide:
            running?.hide()
        case .refuseFullScreen:
            // Hiding the app as a substitute was tried and rejected: Cmd-H
            // tears down the full-screen space, after which the app reports
            // no windows while AXHidden stays false and nothing can bring it
            // back.
            Notify.show("macOS can't minimize a full-screen window", symbol: "macwindow")
        }
    }

    /// The windows each app's last minimise put down, by process, so the
    /// click that brings them back brings back those and not every window
    /// the app has in the Dock. A process id rather than a bundle id: a
    /// relaunched app has new windows, and stale elements must not match.
    private static var minimizedByRoost: [pid_t: [AXUIElement]] = [:]

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    // MARK: - New window

    /// Presses the app's own "New Window" menu item over the Accessibility API.
    ///
    /// There is no public call for this. NSWorkspace can launch an app or
    /// activate it, and `createsNewApplicationInstance` gives you a second
    /// copy of the process, not a second window. So every launcher that offers
    /// this drives the app's menu bar, which is what the Dock does too.
    ///
    /// The item is searched for rather than indexed: it is usually File > New
    /// Window, but Finder calls it New Finder Window, terminals offer New
    /// Window and New Tab, and the menu is localized. Matching on the words
    /// survives all three; an exact "new window" wins over a longer title so
    /// Chrome's "New Incognito Window" never gets picked first.
    static func newWindow(_ app: NSRunningApplication) -> Bool {
        let axApp = appElement(app.processIdentifier)
        guard let menuBar = element(attribute(axApp, kAXMenuBarAttribute as String)),
              let topLevel = attribute(menuBar, kAXChildrenAttribute as String)
                as? [AXUIElement] else { return false }

        var fallback: AXUIElement?

        for menu in topLevel {
            // Each top-level title owns one AXMenu, whose children are items.
            guard let menus = attribute(menu, kAXChildrenAttribute as String) as? [AXUIElement],
                  let items = menus.first.flatMap({
                      attribute($0, kAXChildrenAttribute as String) as? [AXUIElement]
                  }) else { continue }

            for item in items {
                guard let title = (attribute(item, kAXTitleAttribute as String) as? String)?
                        .lowercased() else { continue }
                guard title.contains("window") else { continue }

                if title == "new window" {
                    return press(item, of: app)
                }
                if title.hasPrefix("new"), fallback == nil {
                    fallback = item
                }
            }
        }

        if let fallback {
            return press(fallback, of: app)
        }
        return false
    }

    private static func press(_ item: AXUIElement, of app: NSRunningApplication) -> Bool {
        // Some apps only build their menus once frontmost, so raise first and
        // press on the next turn.
        activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        return true
    }

    // MARK: - Individual windows

    /// A window exposed to the menu: enough to label it and raise it.
    struct WindowRef {
        /// How to get to the window.
        ///
        /// Electron apps -- VS Code, Antigravity, Discord -- publish no
        /// windows at all through kAXWindowsAttribute, so there was nothing to
        /// list and the Windows section never appeared for them. Their Window
        /// *menu* lists every window, which is the same place the Dock reads
        /// from, so a window can be a menu item instead of an AX window.
        enum Handle {
            case window(AXUIElement)
            case menuItem(AXUIElement)
        }
        let handle: Handle
        let title: String
        let isMinimized: Bool
    }

    static func windowList(for app: NSRunningApplication) -> [WindowRef] {
        let axApp = appElement(app.processIdentifier)

        let axWindows = windows(of: axApp)
        if !axWindows.isEmpty {
            return axWindows.map { window in
                WindowRef(handle: .window(window),
                          title: (attribute(window, kAXTitleAttribute as String) as? String) ?? "Untitled",
                          isMinimized: bool(window, kAXMinimizedAttribute as String))
            }
        }

        return menuWindowList(of: axApp)
    }

    /// Finds a menu item by its keyboard equivalent, and the menu holding it.
    ///
    /// By shortcut rather than by title because titles are localised --
    /// "Beenden", "Fenster" -- while ⌘Q is Quit and ⌘M is Minimize in every
    /// localisation, and nothing else in the menu bar claims either.
    private static func menuItem(of axApp: AXUIElement,
                                 cmdChar: String,
                                 modifiers: Int = 0) -> (item: AXUIElement, menu: AXUIElement)? {
        guard let bar = element(attribute(axApp, kAXMenuBarAttribute as String))
        else { return nil }
        let topLevel = (attribute(bar, kAXChildrenAttribute as String)
                        as? [AXUIElement]) ?? []
        for top in topLevel {
            guard let menu = (attribute(top, kAXChildrenAttribute as String)
                              as? [AXUIElement])?.first else { continue }
            let items = (attribute(menu, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
            for item in items {
                let character = (attribute(item, kAXMenuItemCmdCharAttribute as String) as? String)?
                    .lowercased()
                let mods = (attribute(item, kAXMenuItemCmdModifiersAttribute as String) as? Int) ?? -1
                if character == cmdChar && mods == modifiers { return (item, menu) }
            }
        }
        return nil
    }

    /// The app's own Window menu, found by the ⌘M in it.
    private static func windowMenu(of axApp: AXUIElement) -> AXUIElement? {
        menuItem(of: axApp, cmdChar: "m")?.menu
    }

    /// The windows listed at the bottom of the Window menu.
    ///
    /// AppKit appends them after the menu's last separator, so everything past
    /// the last item with no title is a window. An app with no windows open
    /// has no trailing block at all -- checked against Notes, which has none,
    /// and against Terminal, whose two entries match what AX reports anyway.
    private static func menuWindowList(of axApp: AXUIElement) -> [WindowRef] {
        guard let menu = windowMenu(of: axApp) else { return [] }
        let items = (attribute(menu, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []

        var lastSeparator = -1
        for (index, item) in items.enumerated()
        where ((attribute(item, kAXTitleAttribute as String) as? String) ?? "").isEmpty {
            lastSeparator = index
        }
        guard lastSeparator >= 0, lastSeparator + 1 < items.count else { return [] }

        return items[(lastSeparator + 1)...].compactMap { item in
            guard let title = attribute(item, kAXTitleAttribute as String) as? String,
                  !title.isEmpty else { return nil }
            return WindowRef(handle: .menuItem(item), title: title, isMinimized: false)
        }
    }

    /// Bring one specific window forward, unminimizing it first if needed.
    static func raise(_ window: WindowRef, of app: NSRunningApplication) {
        switch window.handle {
        case .window(let element):
            if window.isMinimized { setMinimized(element, false) }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            activate(app)
        case .menuItem(let item):
            // Pressing the app's own menu entry is what the Dock does, and it
            // raises and unminimises in one step.
            _ = press(item, of: app)
        }
    }

    /// Quit, the way ⌘Q does.
    ///
    /// Not NSRunningApplication.terminate(): that posts a quit Apple Event,
    /// which macOS gates behind the Automation permission. Roost never asks
    /// for Automation, so the call returned true and the app simply stayed
    /// open -- measured on TextEdit, and the reason Quit appeared to do
    /// nothing. Pressing the app's own Quit item needs only Accessibility,
    /// which Roost already uses for window control, and behaves exactly like
    /// ⌘Q, save prompts included.
    static func quit(_ app: NSRunningApplication) {
        let axApp = appElement(app.processIdentifier)
        if let quitItem = menuItem(of: axApp, cmdChar: "q")?.item {
            _ = press(quitItem, of: app)
            return
        }
        // An app with no menu bar -- an agent, or one that has not built one
        // yet. The Apple Event is all that is left, and it may do nothing.
        app.terminate()
    }

    // MARK: - One thing at a time

    /// The options menu asks for one specific thing, so these do exactly what
    /// they say -- unlike toggle(), which picks the next sensible step and can
    /// therefore minimize an app you meant to raise.

    static func bringToFront(_ entry: AppEntry) {
        if restore(entry.bundleID) { return }
        if !launch(entry.bundleID) { Notify.show("\(entry.name) is not installed") }
    }

    static func minimize(_ bundleID: String) {
        guard ensureTrusted(for: "Minimising a window"),
              let running = runningApp(bundleID) else { return }
        let axApp = appElement(running.processIdentifier)
        guard let window = targetWindow(of: axApp) else { return }
        if bool(window, "AXFullScreen") {
            Notify.show("macOS can't minimize a full-screen window", symbol: "macwindow")
            return
        }
        setMinimized(window, true)
    }

    static func hide(_ app: NSRunningApplication) {
        app.hide()
    }

    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Reveals the .app in Finder, for when you want the bundle rather than
    /// the running program.
    static func revealInFinder(_ bundleID: String) {
        guard let url = appURL(bundleID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Running apps that show up in the UI, for the auto-discovered section.
    static func runningRegularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "")
                        == .orderedAscending }
    }

    /// Bring an app forward without the minimise half of toggle().
    ///
    /// Cycling must only ever raise: if it toggled, stepping onto the app you
    /// are already in would hide it instead of switching to it.
    static func toggleActivateOnly(_ app: NSRunningApplication) {
        defer { invalidateState(app.bundleIdentifier) }
        if app.isHidden { app.unhide() }
        let axApp = appElement(app.processIdentifier)
        if let window = targetWindow(of: axApp),
           bool(window, kAXMinimizedAttribute as String) {
            setMinimized(window, false)
        }
        activate(app)
    }

    /// Used by the minimize/restore hotkey.
    static func minimizeFrontmost() -> String? {
        guard ensureTrusted(for: "Minimising a window") else { return nil }
        defer { invalidateState(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
        guard let running = NSWorkspace.shared.frontmostApplication,
              let bundleID = running.bundleIdentifier else { return nil }

        let axApp = appElement(running.processIdentifier)
        guard let window = targetWindow(of: axApp) else { return nil }

        if bool(window, "AXFullScreen") {
            Notify.show("macOS can't minimize a full-screen window", symbol: "macwindow")
            return nil
        }
        setMinimized(window, true)
        return bundleID
    }

    static func restore(_ bundleID: String) -> Bool {
        defer { invalidateState(bundleID) }
        guard let running = runningApp(bundleID) else { return false }
        if running.isHidden { running.unhide() }

        let axApp = appElement(running.processIdentifier)
        if let window = targetWindow(of: axApp),
           bool(window, kAXMinimizedAttribute as String) {
            setMinimized(window, false)
        }
        activate(running)
        return true
    }
}
