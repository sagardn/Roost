import AppKit
import UserNotifications

/// What happens between launching and running.
///
/// Arguments are applied, the settings store is brought up to date with the
/// version that is running, the first-run window gets its chance, and the
/// three background schedules are armed. The decisions these make are in
/// `StartupDecisions`, which is testable; what is left here is the part that
/// touches AppKit, the settings store and the notification centre.
extension AppDelegate {

    // MARK: - Arguments

    internal func parseArguments() {
        let arguments = LaunchArguments.parse(CommandLine.arguments)

        // Registering wins if somebody passes both, because the case that
        // brings somebody to the command line is a login item pointing at the
        // wrong copy, and the fix for that is to register the right one.
        if arguments.registerLoginItem {
            if LoginItem.isRunningFromBuildDirectory {
                // A build copy registers a login item that points into a
                // derived data directory, which is then wrong the moment that
                // directory is cleaned -- and cannot be repaired from the
                // installed copy, because only the registered bundle can
                // unregister itself.
                NSLog("Roost: --register-login-item refused, this is a build copy")
            } else {
                LoginItem.isEnabled = true
                NSLog("Roost: login item now points at \(Bundle.main.bundleURL.path)")
            }
        } else if arguments.unregisterLoginItem {
            LoginItem.isEnabled = false
            NSLog("Roost: login item removed for \(Bundle.main.bundleURL.path)")
        }

        if arguments.reset {
            Log.debug("--reset: clearing the settings store")
            Preferences.shared.reset()
        }

        for name in arguments.disabledModules {
            guard let module = ModuleRegistry.shared.all.first(where: {
                $0.moduleName.lowercased() == name
            }) else {
                Log.debug("--disable: no module called \(name)")
                continue
            }
            module.isEnabled = false
        }
    }

    // MARK: - The version that is running

    /// Records the running version, and says so if it just went up.
    internal func parseVersion() {
        let key = "version"
        let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

        guard let interval = UpdateInterval(rawValue: Preferences.shared.string(
            "update-interval", default: UpdateInterval.defaultStored)) else { return }

        // No version recorded at all means either a first run or a store
        // written by something that is not this app. Starting clean is the
        // only state that can be reasoned about afterwards.
        guard Preferences.shared.exists(key) else {
            Preferences.shared.reset()
            Preferences.shared.set(key, current)
            Log.debug("no previous version recorded; starting at \(current)")
            return
        }

        let previous = Preferences.shared.string(key, default: "")
        guard previous != current else { return }

        if FormerName.migratedThisLaunch {
            // In place of "updated": this launch gets one notice, and the
            // name is the news. Left up, unlike the update notice -- it says
            // what to do about the login item.
            Notice.post(title: localized("Perch is now Roost"),
                        detail: localized("Your settings came with it. If Perch started at login, turn Start at login on again in Settings."),
                        delegate: self)
        } else if StartupDecisions.announcesUpdate(from: previous, to: current,
                                                   silent: interval == .silent) {
            let id = Notice.post(title: localized("Successfully updated"),
                                 detail: localized("Roost was updated to v", current),
                                 delegate: self)
            // Taken down rather than left for the user to dismiss: it is an
            // acknowledgement, not something to act on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                Notice.withdraw(id)
            }
        }

        Log.debug("version moved from \(previous) to \(current)")
        Preferences.shared.set(key, current)
    }

    // MARK: - First run

    /// Shows the first-run window, or gets out of the way.
    ///
    /// `runAtLoginInitialized` is the key the first version of this app used.
    /// It is still read so that upgrading does not show somebody the
    /// first-run window again.
    internal func setup(completion: @escaping () -> Void) {
        let alreadySetUp = Preferences.shared.exists("setupProcess")
            || Preferences.shared.exists("runAtLoginInitialized")
        guard !alreadySetUp else {
            completion()
            return
        }

        Log.debug("showing the setup window")
        let window = ensureSetupWindow()
        window.finishHandler = {
            Log.debug("setup finished; starting the app")
            completion()
        }
        window.show()
        Preferences.shared.set("setupProcess", true)
    }

    // MARK: - Schedules

    internal func defaultValues() {
        if Preferences.shared.exists("runAtLoginInitialized") {
            LoginItem.migrateLegacyRegistration()
        }

        if Preferences.shared.exists("dockIcon") {
            NSApp.setActivationPolicy(
                Preferences.shared.bool("dockIcon", default: false) ? .regular : .accessory)
        }

        scheduleSupportChecks()
        scheduleUpdateChecks()
    }

    /// Two schedules, not one, and they ask different questions.
    ///
    /// The monthly one asks whether enough time has passed to put the support
    /// window in front of somebody. The half-hourly one asks whether a prompt
    /// that is already due can be shown *yet* -- it exists because the first
    /// one will almost always find the machine busy, locked or unattended,
    /// and without a retry the prompt would wait a month for another chance.
    private func scheduleSupportChecks() {
        checkIfShouldShowSupportWindow()

        supportActivity.interval = 86_400 * 30
        supportActivity.repeats = true
        supportActivity.schedule { completion in
            DispatchQueue.main.async { self.checkIfShouldShowSupportWindow() }
            completion(.finished)
        }

        supportRetryActivity.interval = 60 * 30
        supportRetryActivity.repeats = true
        supportRetryActivity.schedule { completion in
            DispatchQueue.main.async { self.tryToShowSupportWindow() }
            completion(.finished)
        }
    }

    private func scheduleUpdateChecks() {
        guard let interval = UpdateInterval(rawValue: Preferences.shared.string(
            "update-interval", default: UpdateInterval.defaultStored)) else { return }

        updateActivity.invalidate()
        Log.debug("update interval is '\(interval.rawValue)'")

        // `.atStart` and `.silent` check once, now. `.never` checks never.
        // None of the three is a repeating schedule, which is what a nil
        // interval means -- and why it is nil rather than zero: a zero
        // interval on an NSBackgroundActivityScheduler fires as often as the
        // system allows.
        guard let seconds = StartupDecisions.updateCheckInterval(interval) else {
            switch interval {
            case .atStart: checkForNewVersion()
            case .silent:  checkForNewVersion(silent: true)
            default:       break
            }
            return
        }

        updateActivity.repeats = true
        updateActivity.interval = seconds
        updateActivity.schedule { completion in
            self.checkForNewVersion()
            completion(.finished)
        }
    }
}
