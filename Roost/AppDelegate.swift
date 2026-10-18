import AppKit
import UserNotifications

/// The updater, shared.
///
/// Both of its sources are this fork's own GitHub releases -- see `AppLinks`.
/// It tries the primary feed first and falls back to the GitHub API, which
/// here is the same endpoint, so a rate-limited or flaky response gets a
/// second attempt rather than a silent failure.
let appUpdater = AppUpdater(repository: AppLinks.repository)

/// The modules this build runs, in menu bar order.
///
/// All six are Roost's own: readings, popups, tiles, menu bar shapes,
/// settings and alerts, all in `Roost/Monitor/`. Every module they replaced
/// is gone, and so is the array of framework-backed ones that used to sit
/// beside this and the bridge that let the shell treat the two kinds alike.
///
/// Battery and Bluetooth are not here and are not coming back: macOS already
/// shows both, so Roost showing them again was duplication to maintain rather
/// than a feature. `Remote` is absent for a different reason -- it was a
/// client for the original author's hosted service, which a fork has nothing
/// to connect to.
let allModules: [any RoostModule] = [
    CPUModule(),
    GPUModule(),
    RAMModule(),
    DiskModule(),
    SensorsModule(),
    NetworkModule(),
    // Last, so an existing menu bar keeps its order when it is switched on.
    // Not a monitor, but a module in every way the shell cares about: a
    // switch, an item, a popup, a page.
    ClipboardModule.shared
]

/// Application lifecycle.
///
/// Deliberately thin. What used to be here is in `Roost/Startup/`: the launch
/// arguments and the diagnostics they drive, the version transition, the
/// background schedules, the support prompt and the popup shortcut. What is
/// left is the order things happen in, the four windows, and the handful of
/// notifications the rest of the app sends this way.
@main
final class AppDelegate: NSObject, NSApplicationDelegate,
                         UNUserNotificationCenterDelegate {

    // MARK: - Windows

    internal var settingsWindow: SettingsWindow?
    internal var updateWindow: UpdateWindow?
    internal var setupWindow: SetupWindow?
    internal var supportWindow: SupportWindow?

    // MARK: - State

    /// The single status item shown while every module is paused.
    internal var menuBarItem: NSStatusItem?
    internal var modulesMounted = false

    internal let updateActivity = NSBackgroundActivityScheduler(
        identifier: "com.sagar.roost.updateCheck")
    internal let supportActivity = NSBackgroundActivityScheduler(
        identifier: "com.sagar.roost.support")
    internal let supportRetryActivity = NSBackgroundActivityScheduler(
        identifier: "com.sagar.roost.supportRetry")

    /// Set when a notification was clicked, so the reopen that follows is not
    /// mistaken for the user asking for the settings window.
    internal var clickInNotification = false

    /// Held so they can be removed again -- see `syncPopupKeyMonitor()`.
    internal var popupKeyGlobalMonitor: Any?
    internal var popupKeyLocalMonitor: Any?

    internal var pauseState: Bool {
        Preferences.shared.bool("pause", default: false)
    }

    /// When launching finished, used to ignore the reopen macOS sends
    /// immediately afterwards.
    private var readyAt: Date?

    // MARK: - Launch

    /// `main` by hand rather than `@NSApplicationMain`, for one reason: the
    /// clock has to start before `NSApplication` is touched, or the launch
    /// time this logs excludes the slowest part of it.
    static func main() {
        let began = Date()
        // Before anything reads a preference: the old name's settings have to
        // be in place before `Preferences` is first asked for one.
        FormerName.migrate()
        let delegate = AppDelegate()
        delegate.launchBegan = began
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    private var launchBegan: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let began = launchBegan ?? Date()

        ModuleRegistry.shared.register(allModules)
        suppressStatusBarTilingConstraintUpdates()

        let arguments = LaunchArguments.parse(CommandLine.arguments)
        parseArguments()
        parseVersion()

        // The modules start inside `setup`'s completion, because on a first
        // run that completion does not come until the first-run window is
        // finished with -- and starting them before it would put widgets in
        // the menu bar behind a window asking which ones to show.
        setup {
            ModuleRegistry.shared.startAll()
            RunawayApps.shared.start()
            Throttling.startWatching()
            // After the modules: the menu bar is built from what they say
            // about themselves, so started first the combined row would be
            // laid out before there was anything in it.
            MonitorBar.shared.start()
            self.modulesMounted = true
            self.showSettingsIfNothingVisible()
        }

        defaultValues()
        refreshPausedMenuBarItem()

        // The app-switcher half: Ctrl+Space search, per-app hotkeys, the
        // minimise/restore key and the trackpad gesture. It shares nothing
        // with the module system above.
        Launcher.shared.start()

        warnIfRunningFromBuildDirectory()
        observeNotifications()
        syncPopupKeyMonitor()
        runDiagnostics(arguments)

        Log.info(String(format: "Roost started in %.4f seconds",
                        -began.timeIntervalSinceNow))
        readyAt = Date()
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(listenForAppPause),
                           name: .pause, object: nil)
        center.addObserver(self, selector: #selector(handleToggleSettings),
                           name: .toggleSettings, object: nil)
        center.addObserver(self, selector: #selector(handlePopupVisibility),
                           name: .popupVisibilityChanged, object: nil)
        center.addObserver(self, selector: #selector(syncPopupKeyMonitor),
                           name: .popupKeyboardShortcutChanged, object: nil)
    }

    /// Says so, loudly, when the copy that started is a build product.
    ///
    /// Not hypothetical: a login item registered from Xcode kept starting a
    /// months-old debug build out of DerivedData while the real app sat in
    /// /Applications. Every shipped fix was invisible, the updater never saw a
    /// newer release, and macOS re-asked for Accessibility after every
    /// rebuild. Silent misconfiguration that looks exactly like a broken app
    /// deserves a sentence on screen.
    private func warnIfRunningFromBuildDirectory() {
        guard LoginItem.isRunningFromBuildDirectory else { return }

        let installed = LoginItem.installedLocation != nil
        NSLog("Roost: running from a build directory (\(Bundle.main.bundleURL.path))"
              + (installed ? "; an installed copy exists in /Applications" : ""))
        Notify.show(installed
                    ? "This is a build copy — the app in /Applications is the real one"
                    : "Running from a build folder — move Roost to /Applications",
                    symbol: "hammer.fill", for: 6)
    }

    // MARK: - Shutdown

    func applicationWillTerminate(_ notification: Notification) {
        ModuleRegistry.shared.stopAll()
        MonitorBar.shared.stop()
        // Separately from the module's stop(), which also runs when its menu
        // bar item is switched off -- and history must not stop with it.
        ClipboardService.shared.stop()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Reopening

    /// Clicking the app in Finder or the Dock while it is already running.
    ///
    /// For a menu bar app there is nothing to bring forward, so this is read
    /// as "show me the settings" -- with two exceptions. A reopen that follows
    /// a notification click belongs to the notification. And one that arrives
    /// within two seconds of launch is macOS's own, not the user's: answering
    /// it would open the settings window at every login.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if clickInNotification {
            clickInNotification = false
            return true
        }
        guard let readyAt, Date().timeIntervalSince(readyAt) > 2 else { return false }

        let window = ensureSettingsWindow()
        if hasVisibleWindows {
            window.makeKeyAndOrderFront(self)
        } else {
            window.setIsVisible(true)
        }
        return true
    }

    // MARK: - Notifications from the rest of the app

    @objc private func handleToggleSettings(_ notification: Notification) {
        ensureSettingsWindow().open(module: notification.userInfo?["module"] as? String)
    }

    /// A popup closing is evidence somebody is at the machine, which is the
    /// one thing the support prompt waits for.
    @objc private func handlePopupVisibility(_ notification: Notification) {
        guard let visible = notification.userInfo?["state"] as? Bool, !visible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.tryToShowSupportWindow(interaction: true)
        }
    }

    /// Opens settings when the menu bar would otherwise be empty.
    ///
    /// Showing nothing at all looks like a crashed app. "Showing something"
    /// means a module that is on, available, *and* has a menu bar window --
    /// all three, because a module can be switched on and still have nothing
    /// to draw on this Mac.
    private func showSettingsIfNothingVisible() {
        guard !pauseState else { return }
        let anyVisible = ModuleRegistry.shared.all.contains {
            $0.isEnabled && $0.isAvailable && $0.menuBarWindow != nil
        }
        guard !anyVisible else { return }
        ensureSettingsWindow().setIsVisible(true)
    }

    // MARK: - The four windows

    internal func ensureSettingsWindow() -> SettingsWindow {
        ensure(\.settingsWindow, make: SettingsWindow.init) { [weak self] in
            // Closing settings is an interaction, and a good moment to ask
            // about supporting the app.
            self?.tryToShowSupportWindow(interaction: true)
        }
    }

    internal func ensureUpdateWindow() -> UpdateWindow {
        ensure(\.updateWindow) { UpdateWindow(updater: appUpdater) }
    }

    internal func ensureSetupWindow() -> SetupWindow {
        ensure(\.setupWindow, make: SetupWindow.init)
    }

    internal func ensureSupportWindow() -> SupportWindow {
        ensure(\.supportWindow, make: SupportWindow.init)
    }

    /// Makes a window on demand and forgets it when it closes.
    ///
    /// Four windows had four copies of this, which is three too many for a
    /// pattern whose whole content is "drop the reference in `onClose`" --
    /// and dropping it is the part that matters: these are all
    /// `isReleasedWhenClosed = false`, so a reference kept after a close is a
    /// window that can never be rebuilt in its first state.
    private func ensure<Window: AnyObject & ClosableWindow>(
        _ stored: ReferenceWritableKeyPath<AppDelegate, Window?>,
        make: () -> Window,
        thenOnClose extra: (() -> Void)? = nil) -> Window {

        if let existing = self[keyPath: stored] { return existing }

        let window = make()
        window.onClose = { [weak self] in
            self?[keyPath: stored] = nil
            extra?()
        }
        self[keyPath: stored] = window
        return window
    }

    // MARK: - Notification clicks

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        clickInNotification = true

        // "Quit" on a runaway-app alert, or a click on one.
        if RunawayApps.handle(response) {
            completionHandler()
            return
        }

        // The url in the notification says a release existed when it was
        // posted, not that it is still the newest or that it is genuine -- so
        // the check runs again and the download is verified against what it
        // answers, checksum included. The url is only read as "the user wants
        // the update".
        if response.notification.request.content.userInfo["url"] is String {
            Log.debug("update notification clicked; re-checking before installing")
            appUpdater.check { result in
                guard case .success(.available(let release)) = result else { return }
                appUpdater.download(release) { outcome in
                    guard case .success(let image) = outcome else { return }
                    appUpdater.install(image) { error in
                        if let error {
                            Alert.show("Could not install the update", error: error)
                        }
                    }
                }
            }
        }

        completionHandler()
    }
}

/// A window that tells its owner when it has closed.
///
/// All four of Roost's windows are built on demand and dropped on close, so
/// the next open gets a fresh one rather than whatever state the last one was
/// left in. This is the one thing `ensure` needs of them.
protocol ClosableWindow: AnyObject {
    var onClose: (() -> Void)? { get set }
}

extension SettingsWindow: ClosableWindow {}
extension UpdateWindow: ClosableWindow {}
extension SetupWindow: ClosableWindow {}
extension SupportWindow: ClosableWindow {}
