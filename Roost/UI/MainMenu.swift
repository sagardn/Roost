import AppKit

/// The application's main menu: App, Edit and Window.
///
/// Roost had none. It is a menu bar app, so the menu is seldom seen -- but
/// AppKit delivers ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z to a text field through the main
/// menu's key equivalents, and with no menu they went nowhere. Checked by
/// focusing the settings sidebar's search field and sending ⌘A: nothing was
/// selected. The same was true of every field in Roost -- the clipboard
/// history's search, the colour fields, the shortcut lists. And with Show in
/// Dock on, Roost becomes a regular app and the menu bar showed an empty
/// menu where its own should have been.
///
/// Every action goes to the first responder, so each item works in whatever
/// window and field has focus, and greys out where it means nothing.
extension AppDelegate {

    internal func installMainMenu() {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu(), title: "Roost"))
        menu.addItem(submenu(editMenu(), title: localized("Edit")))
        menu.addItem(submenu(windowMenu(), title: localized("Window")))
        NSApp.mainMenu = menu
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: localized("About Roost"),
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: localized("Settings") + "…",
                                    action: #selector(openAppSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("Hide Roost"),
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = menu.addItem(withTitle: localized("Hide Others"),
                                  action: #selector(NSApplication.hideOtherApplications(_:)),
                                  keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: localized("Show All"),
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // No ⌘Q. The settings window takes ⌘Q to mean "close this window",
        // deliberately -- see `SettingsWindow.performKeyEquivalent` -- and a
        // menu that quit the monitor from Roost's other windows would break
        // that promise everywhere but there. Quit is in the menu, and in the
        // sidebar's footer, for anyone who means it.
        menu.addItem(withTitle: localized("Quit Roost"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: localized("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: localized("Redo"), action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: localized("Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: localized("Select All"), action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: localized("Minimise"),
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: localized("Zoom"),
                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("Close"),
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = menu
        return menu
    }

    @objc private func openAppSettings() {
        ensureSettingsWindow().open(module: "Settings")
    }
}
