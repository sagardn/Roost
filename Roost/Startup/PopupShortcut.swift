import AppKit

extension AppDelegate {

    /// Watch for popup shortcuts, but only while one is actually set.
    ///
    /// A global keyDown monitor is a system-wide keylogger as far as macOS is
    /// concerned, so asking for one is what makes it offer Roost an Input
    /// Monitoring prompt. Arming it unconditionally meant that dialog at
    /// every launch, for a feature almost nobody uses. The local monitor
    /// stays armed: it sees only this app's own events and needs no
    /// permission.
    @objc internal func syncPopupKeyMonitor() {
        if popupKeyLocalMonitor == nil {
            popupKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    self?.handleKeyEvent(event)
                    return event
                }
        }

        let anyShortcutSet = ModuleRegistry.shared.all.contains { !$0.popupShortcut.isEmpty }

        switch (anyShortcutSet, popupKeyGlobalMonitor) {
        case (true, nil):
            popupKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    self?.handleKeyEvent(event)
                }
        case (false, let monitor?):
            NSEvent.removeMonitor(monitor)
            popupKeyGlobalMonitor = nil
        default:
            break
        }
    }

    internal func handleKeyEvent(_ event: NSEvent) {
        let pressed = PopupShortcut.keyCodes(modifiers: event.modifierFlags,
                                             keyCode: event.keyCode)

        // Clipboard history answers its shortcut with its menu bar item
        // hidden too -- the history window then -- so it is checked before
        // the rule below, which only considers modules that are in the bar.
        if !ClipboardSettings.shortcut.isEmpty, pressed == ClipboardSettings.shortcut {
            ClipboardModule.shared.openFromShortcut()
            return
        }

        guard let module = ModuleRegistry.shared.all.first(where: {
            $0.isEnabled && $0.popupShortcut == pressed
        }), let window = module.menuBarWindow else { return }

        if MonitorBar.shared.openPopup(for: module.moduleName) { return }

        // No "widget" key in the payload. It exists so that clicking a
        // *different* widget of the same module reopens the popup rather than
        // toggling it shut, and a module has one keyboard shortcut -- so there
        // is no other widget for the press to have come from.
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
            "module": module.moduleName,
            "origin": window.frame.origin,
            "center": window.frame.width / 2
        ])
    }
}
