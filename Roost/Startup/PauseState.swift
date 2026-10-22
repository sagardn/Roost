import AppKit

extension AppDelegate {

    /// Take every module out of the menu bar, or put back the ones that were
    /// there.
    ///
    /// By stopping and starting them, never by switching them. A module's
    /// `isEnabled` setter saves `<module>_state` -- it is the user's choice --
    /// and pausing used to set it false on every module. Resume then read
    /// those saved values back to decide what to restore, found false
    /// everywhere and restored nothing: one click of Pause left an empty menu
    /// bar that a relaunch kept, since the states were saved. `start()` shows
    /// a module only if it is enabled, and `stop()` hides it without saving
    /// anything, so the choices come through a pause untouched.
    @objc internal func listenForAppPause() {
        if pauseState {
            ModuleRegistry.shared.stopAll()
        } else {
            ModuleRegistry.shared.startAll()
        }
        refreshPausedMenuBarItem()
    }

    /// The single menu bar item that stands in for everything while paused.
    ///
    /// Only while paused. Every module draws its own item when running, so
    /// there is nothing for this to do then, and leaving it up would be a
    /// second Roost icon in the menu bar.
    internal func refreshPausedMenuBarItem() {
        guard pauseState else {
            if let item = menuBarItem { NSStatusBar.system.removeStatusItem(item) }
            menuBarItem = nil
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuBarItem = item

        // Async, and not for ordering: setting an autosave name during
        // creation makes AppKit restore a position before the item has one.
        DispatchQueue.main.async { item.autosaveName = "Roost" }

        // The button's own image, not a subview of it. A template image is
        // inverted for a dark menu bar and dimmed while the app is hidden,
        // and a view added underneath the button gets neither.
        item.button?.image = MenuBarIcon.image
        item.button?.target = self
        item.button?.action = #selector(openSettings)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    @objc internal func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil,
                                        userInfo: ["module": "Dashboard"])
    }
}
