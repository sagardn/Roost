import AppKit

/// Roost's own alerts.
///
/// Independent of Kit, so that the components rebuilt in `Roost/` can report a
/// failure without importing the framework they are replacing.
///
/// Two differences from the helper it replaces. It takes the error rather than
/// a pre-flattened string, so the message a user sees comes from
/// `LocalizedError.errorDescription` rather than from whatever the call site
/// happened to interpolate. And it can be given a recovery action, because
/// "the download does not match its checksum" is much more useful next to a
/// button that opens the releases page than next to OK alone.
enum Alert {

    /// Shown with a single OK. Safe from any thread.
    static func show(_ message: String,
                     _ information: String? = nil,
                     style: NSAlert.Style = .informational) {
        present(message, information, style: style, action: nil)
    }

    /// A question with one labelled action, and Cancel.
    ///
    /// Cancel, not OK: nearly every caller asks before doing something, and
    /// "OK" beside "Move to Bin" reads as a second way to agree. A caller
    /// reporting something done, with an action to follow it up, passes
    /// `asks: false` and keeps OK.
    ///
    /// `icon` is for an alert about something other than Roost -- removing
    /// an app should show that app, not Roost's own icon, which is what
    /// NSAlert shows when it is given nothing.
    static func show(_ message: String,
                     _ information: String? = nil,
                     style: NSAlert.Style = .informational,
                     icon: NSImage? = nil,
                     asks: Bool = true,
                     actionTitle: String,
                     action: @escaping () -> Void) {
        present(message, information, style: style, icon: icon, asks: asks,
                action: (actionTitle, action))
    }

    /// Reports an error by what it says about itself.
    static func show(_ message: String, error: Error, style: NSAlert.Style = .critical) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        present(message, detail, style: style, action: nil)
    }

    private static func present(_ message: String,
                                _ information: String?,
                                style: NSAlert.Style,
                                icon: NSImage? = nil,
                                asks: Bool = false,
                                action: (title: String, run: () -> Void)?) {
        let show = {
            let alert = NSAlert()
            alert.messageText = message
            if let information { alert.informativeText = information }
            alert.alertStyle = style
            if let icon { alert.icon = icon }
            // First button is the default, so the action goes second: Return
            // dismisses, and nothing is removed or quit by a reflex.
            alert.addButton(withTitle: asks ? localized("Cancel") : "OK")
            if let action {
                let button = alert.addButton(withTitle: action.title)
                // A warning that asks is a destructive one -- moving to the
                // Bin, force quitting, resetting -- and macOS draws that
                // button red.
                button.hasDestructiveAction = asks && style == .warning
            }

            let response = alert.runModal()
            if let action, response == .alertSecondButtonReturn { action.run() }
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }
}
