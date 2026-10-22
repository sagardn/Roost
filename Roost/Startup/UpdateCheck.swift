import AppKit
import UserNotifications

extension AppDelegate {

    /// Look for a newer release.
    ///
    /// `silent` is the interval that installs without asking: it downloads,
    /// verifies and installs, and the user finds out because the app restarts
    /// into a new version. Everything else notifies, and falls back to a
    /// window when notifications are not permitted -- a user who has refused
    /// notifications has not refused updates.
    internal func checkForNewVersion(silent: Bool = false) {
        appUpdater.check { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                // Logged, not shown: the user did not ask. But logged with
                // what actually went wrong, because a failed check used to be
                // indistinguishable from being up to date.
                let description = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Log.error("update check failed: \(description)")

            case .success(.upToDate):
                Log.debug("no newer release")

            case .success(.available(let release)):
                if silent {
                    self.installSilently(release)
                } else {
                    self.announce(release)
                }
            }
        }
    }

    private func installSilently(_ release: Release) {
        appUpdater.download(release) { outcome in
            // Silent asks for no window, not for no record: a checksum that
            // does not match is worth a line in the log at the least.
            if case .failure(let error) = outcome {
                Log.error("silent update: could not download \(release.version): \(error)")
            }
            guard case .success(let image) = outcome else { return }
            appUpdater.install(image) { error in
                if let error { Alert.show("Could not install the update", error: error) }
            }
        }
    }

    /// Tell the user, by whichever route they have left open.
    private func announce(_ release: Release) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.postUpdateNotification(release)

                case .notDetermined:
                    // Asking is itself a dialog, so this is the one branch
                    // that may show two things in a row. The window is the
                    // fallback for a refusal as well as an error: Don't
                    // Allow is no error, and checking only `error` posted
                    // the notice to a centre that drops it -- the first
                    // update after a refusal was never offered at all.
                    center.requestAuthorization(options: [.sound, .alert, .badge]) { granted, error in
                        DispatchQueue.main.async {
                            guard granted, error == nil else {
                                self.showUpdateWindow(release)
                                return
                            }
                            NSApplication.shared.registerForRemoteNotifications()
                            self.postUpdateNotification(release)
                        }
                    }

                default:
                    self.showUpdateWindow(release)
                }
            }
        }
    }

    private func postUpdateNotification(_ release: Release) {
        Notice.post(title: localized("Roost %0 is available", release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag),
                    detail: localized("Click to install it."),
                    userInfo: ["url": release.downloadURL.absoluteString],
                    delegate: self)
    }

    private func showUpdateWindow(_ release: Release) {
        DispatchQueue.main.async {
            self.ensureUpdateWindow().offer(release)
        }
    }
}
