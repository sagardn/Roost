import AppKit

/// Using an entry: putting it back on the clipboard, saying what happened,
/// and -- only when asked for -- pasting it.
///
/// One function for every place an entry can be chosen from, so the popup,
/// the combined tile and the history window cannot disagree about what a
/// click does.
enum ClipboardActions {

    /// Restores an entry, and pastes it into `target` when automatic paste is
    /// on and possible.
    ///
    /// `target` is the app to paste into: the one in front when the popup
    /// opened, or the one the history window was opened over. Never Roost
    /// itself -- pasting into the window you are choosing from is not a
    /// paste anybody meant.
    static func use(_ id: UUID, pasteInto target: NSRunningApplication?) {
        let outcome = ClipboardService.shared.restore(id)
        switch outcome {
        case .failed:
            Notify.show(localized("That entry could not be restored: its stored data is missing"),
                        symbol: "exclamationmark.triangle", for: 3)
            return
        case .partial:
            // The text went back; the formatting or image it also had did
            // not. Said, rather than letting a plain paste look like the
            // whole thing.
            Notify.show(localized("Copied the text only. The rest of it could not be read back"),
                        symbol: "exclamationmark.circle", for: 3)
        case .complete:
            break
        }

        guard ClipboardSettings.autoPaste else {
            if outcome == .complete {
                Notify.show(localized("Copied. Press ⌘V to paste"), symbol: "doc.on.clipboard")
            }
            return
        }
        switch paste(into: target) {
        case .sent(let name):
            // "Sent", not "pasted": a key event goes out, and nothing comes
            // back to say the app took it.
            Notify.show(localized("Sent ⌘V to %0", name), symbol: "doc.on.clipboard")
        case .needsPermission:
            Notify.show(localized("Copied. Pasting for you needs window control in Settings"),
                        symbol: "lock", for: 3)
        case .noTarget:
            Notify.show(localized("Copied. Press ⌘V to paste"), symbol: "doc.on.clipboard")
        }
    }

    enum PasteResult: Equatable {
        case sent(String)
        case needsPermission
        case noTarget
    }

    /// ⌘V to another app.
    ///
    /// The one thing here that needs a permission: posting a key event is
    /// what Accessibility governs. Roost already asks for it for window
    /// control, so nothing new is requested -- and if it has not been given,
    /// this does nothing and says so, rather than asking again on its own.
    static func paste(into target: NSRunningApplication?) -> PasteResult {
        guard let target, !target.isTerminated,
              target.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = target.localizedName else { return .noTarget }
        guard AXIsProcessTrusted() else { return .needsPermission }

        target.activate()
        // Long enough for the app to take focus back from the popup or the
        // history window; a ⌘V sent sooner lands in whichever had it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
        return .sent(name)
    }

    /// The app in front, unless it is Roost.
    static var otherFrontmostApp: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    // MARK: - Turning it on

    /// Turns monitoring on, after the privacy note the first time.
    ///
    /// The note says plainly what will be kept, where, and what is never
    /// kept, before anything is. Turning it on again after that asks
    /// nothing: the person has read it.
    static func enableMonitoring() {
        guard !ClipboardSettings.privacyAccepted else {
            ClipboardSettings.monitoring = true
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("Turn on clipboard history?")
        // Three keys, not one multi-line literal: i18n.py scan reads
        // localized("…") calls, and a triple-quoted string is invisible to it.
        alert.informativeText = [
            localized(
                "Roost will keep the text and images you copy so you can use them again. They are stored only on this Mac, readable by your account alone, and never sent anywhere."),
            localized("They are not encrypted beyond what your account and FileVault already provide."),
            localized("Copies that apps mark as private, such as passwords from a password manager, are never kept, and you can exclude other apps in Settings."),
            localized("macOS may ask whether Roost can read what you copy. Choose Allow for history to work.")
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: localized("Turn On"))
        alert.addButton(withTitle: localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClipboardSettings.privacyAccepted = true
        ClipboardSettings.monitoring = true
    }

    /// The Privacy & Security pane, where macOS lists the apps that may read
    /// the clipboard.
    static func openPrivacySettings() {
        for address in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                        "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    /// What macOS currently says about Roost reading the clipboard, in words.
    static var accessDescription: String {
        guard #available(macOS 15.4, *) else { return localized("Allowed") }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return localized("Allowed")
        case .alwaysDeny:  return localized("Blocked in System Settings")
        case .ask:         return localized("macOS asks each time")
        default:           return localized("macOS will ask the first time")
        }
    }
}
