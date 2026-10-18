import AppKit

/// Asking, once in a while, whether somebody wants to support Roost.
///
/// Three states, stored in preferences: not due, due-but-not-yet-shown
/// ("pending"), and shown. The pending state is the whole design. The window
/// is a donation prompt, so the moment it becomes due is almost never a
/// moment it should appear -- the screen may be locked, nobody may be at the
/// machine, something may be being presented. Becoming due and being shown
/// are therefore separate steps, and the second one retries.
///
/// The decisions are in `StartupDecisions`, where they can be checked against
/// dates written down.
extension AppDelegate {

    /// Has enough time passed to ask again?
    public func checkIfShouldShowSupportWindow() {
        // Never during first run. Somebody still deciding whether to keep the
        // app has not yet been given a reason to support it.
        let setUp = Preferences.shared.exists("setupProcess")
            || Preferences.shared.exists("runAtLoginInitialized")
        guard setUp else { return }

        let now = Int(Date().timeIntervalSince1970)

        // First time through: start the clock rather than asking immediately.
        guard Preferences.shared.exists("support_ts") else {
            Preferences.shared.set("support_ts", now)
            return
        }

        // Already waiting for a good moment; this is that moment's turn to
        // be tested, not a new decision.
        if Preferences.shared.bool("support_pending", default: false) {
            tryToShowSupportWindow()
            return
        }

        let lastAsked = Preferences.shared.int("support_ts", default: now)
        guard StartupDecisions.shouldAskForSupport(lastAsked: lastAsked, now: now) else {
            Log.debug("support window was shown \((now - lastAsked) / 86_400) days ago")
            return
        }

        markSupportPending()
    }

    /// Mark the prompt due, and have a first go at showing it.
    internal func markSupportPending() {
        if !Preferences.shared.bool("support_pending", default: false) {
            Preferences.shared.set("support_pending", true)
            Preferences.shared.set("support_pending_ts", Int(Date().timeIntervalSince1970))
        }
        tryToShowSupportWindow()
    }

    /// Show the prompt if now is a reasonable time.
    ///
    /// `interaction` means this was reached because the user just did
    /// something -- closed a popup, clicked in settings -- which is both
    /// evidence they are present and the only way past the busy check for a
    /// prompt that has been waiting over a week.
    public func tryToShowSupportWindow(interaction: Bool = false) {
        guard Preferences.shared.bool("support_pending", default: false) else { return }

        let now = Int(Date().timeIntervalSince1970)
        let pendingSince = Preferences.shared.int("support_pending_ts", default: now)
        let pendingDays = max(0, (now - pendingSince) / 86_400)

        // Off the main thread: `Presence.busyReason` asks about displays and
        // running processes, and the caller is often inside an event handler.
        DispatchQueue.global(qos: .utility).async {
            let reason = StartupDecisions.supportDelayReason(
                interaction: interaction,
                pendingDays: pendingDays,
                screenIsLocked: Presence.isScreenLocked,
                secondsSinceInput: Presence.secondsSinceInput,
                busyReason: Presence.busyReason())

            if let reason {
                Log.debug("support window delayed: \(reason)")
                return
            }

            DispatchQueue.main.async {
                // Re-read: the retry schedule and a user interaction can
                // arrive at the same time, and the prompt must not be shown
                // twice.
                guard Preferences.shared.bool("support_pending", default: false) else { return }
                Preferences.shared.set("support_pending", false)
                Preferences.shared.set("support_ts", Int(Date().timeIntervalSince1970))
                self.ensureSupportWindow().show()
            }
        }
    }
}
