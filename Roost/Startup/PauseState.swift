import AppKit

extension AppDelegate {

    /// Switch every module off, or back to what it was.
    ///
    /// Back to *what it was*, not all on: a module the user had turned off
    /// stays off through a pause and a resume. The stored
    /// `<module>_state` key is the record of their choice, and
    /// `isOnByDefault` is only the fallback for a module that has never been
    /// touched.
    @objc internal func listenForAppPause() {
        for module in ModuleRegistry.shared.all {
            if pauseState {
                if module.isEnabled { module.isEnabled = false }
                continue
            }
            guard !module.isEnabled else { continue }
            if Preferences.shared.bool("\(module.moduleName)_state",
                                       default: module.isOnByDefault) {
                module.isEnabled = true
            }
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
