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

    /// Shown with OK and one labelled action.
    static func show(_ message: String,
                     _ information: String? = nil,
                     style: NSAlert.Style = .informational,
                     actionTitle: String,
                     action: @escaping () -> Void) {
        present(message, information, style: style, action: (actionTitle, action))
    }

    /// Reports an error by what it says about itself.
    static func show(_ message: String, error: Error, style: NSAlert.Style = .critical) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        present(message, detail, style: style, action: nil)
    }

    private static func present(_ message: String,
                                _ information: String?,
                                style: NSAlert.Style,
                                action: (title: String, run: () -> Void)?) {
        let show = {
            let alert = NSAlert()
            alert.messageText = message
            if let information { alert.informativeText = information }
            alert.alertStyle = style
            // First button is the default, so the action goes second: an alert
            // reporting a failure should not have Return trigger something.
            alert.addButton(withTitle: "OK")
            if let action { alert.addButton(withTitle: action.title) }

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
