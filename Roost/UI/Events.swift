import Foundation

/// The notifications the application shell passes around.
///
/// Roost's own, with the same raw strings the names they replace used. The
/// strings matter: a notification is matched by name at runtime, so keeping
/// them identical is what let the shell migrate off the framework one file at
/// a time without a window stopping listening to a menu item.
///
/// Only the ones something in Roost actually posts or observes are here. The
/// set this replaces had fifteen, including two for a hosted service this fork
/// does not run and one for a module that was removed -- an observer for a
/// notification nothing posts is not a feature, it is a method that looks
/// reachable and is not.
extension Notification.Name {

    // MARK: Windows

    /// Open the settings window, optionally on a named pane
    /// (`userInfo["module"]`).
    static let toggleSettings = Notification.Name("toggleSettings")

    /// Open one of the app's other windows -- the updater, support, the
    /// launcher's own -- named in `userInfo`.
    static let openWindow = Notification.Name("openWindow")

    /// Show a module's settings page. Posted by the gear in a popup, so the
    /// popup does not have to know how the settings window is built.
    static let openModuleSettings = Notification.Name("openModuleSettings")

    /// A click landed inside the settings window. Controls that hold a
    /// first-responder -- a text field being edited -- use it to commit.
    static let clickInSettings = Notification.Name("clickInSettings")

    // MARK: Modules

    /// Monitoring was paused or resumed from the settings sidebar.
    static let pause = Notification.Name("pause")

    /// A module was switched on or off. Carries the module name, so the
    /// sidebar row and the module itself stay in step without either holding
    /// a reference to the other.
    static let toggleModule = Notification.Name("toggleModule")

    /// Show or hide the preview in a module's settings page.
    static let togglePreview = Notification.Name("togglePreview")

    // MARK: Popups

    /// Open a module's popup, anchored at `userInfo["origin"]`.
    static let togglePopup = Notification.Name("togglePopup")

    /// A popup opened or closed (`userInfo["state"]`). The support window
    /// waits for a close: it is the one moment the app knows the user is
    /// looking at it and has just finished.
    static let popupVisibilityChanged = Notification.Name("popupVisibilityChanged")

    /// A module's popup keyboard shortcut was set or cleared. The app watches
    /// this so the global key monitor -- and the Input Monitoring prompt that
    /// comes with it -- exists only while a shortcut does.
    static let popupKeyboardShortcutChanged = Notification.Name("popupKeyboardShortcutChanged")
}
