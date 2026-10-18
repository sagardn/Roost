import AppKit

/// Doing what a QuickSearch row asks. Kept out of QuickSearch itself so the
/// parsing stays testable without touching the pasteboard or the system.
extension QuickSearch.Result {

    /// The row's picture: an equals sign for a sum, arrows for a
    /// conversion, the action's own symbol otherwise.
    var symbol: String {
        switch self {
        case .answer(let title, _):
            return title.range(of: #" (in|to|as|into) "#, options: .regularExpression) != nil
                ? "arrow.left.arrow.right.circle.fill" : "equal.circle.fill"
        case .action(let action):
            return action.symbol
        }
    }

    var title: String {
        switch self {
        case .answer(let title, _): return title
        case .action(let action):   return action.title
        }
    }

    func perform() {
        switch self {
        case .answer(_, let copy):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
            Notify.show(localized("Copied %0", copy), symbol: "doc.on.clipboard", for: 1.5)
        case .action(let action):
            action.perform()
        }
    }
}

extension QuickSearch.Action {

    func perform() {
        switch self {
        case .lockScreen:
            // ⌃⌘Q is the system's own lock shortcut; posting it is the one
            // public way to lock, and it needs the Accessibility grant Roost
            // already holds for window control.
            guard WindowControl.ensureTrusted(for: localized("Lock Screen")) else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)  // Q
                event?.flags = [.maskCommand, .maskControl]
                event?.post(tap: .cghidEventTap)
            }
        case .sleep:
            run("/usr/bin/pmset", "sleepnow")
        case .sleepDisplay:
            run("/usr/bin/pmset", "displaysleepnow")
        case .screenSaver:
            let saver = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            NSWorkspace.shared.openApplication(at: saver, configuration: .init())
        case .toggleDarkMode:
            // System Events, the documented route; macOS asks once whether
            // Roost may control it.
            script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .emptyBin:
            // The one action here that cannot be undone, so it asks -- and
            // Cancel is the default, so Return does not empty it by habit.
            let alert = NSAlert()
            alert.messageText = localized("Empty the Bin?")
            alert.informativeText = localized("Everything in the Bin is deleted for good. This cannot be undone.")
            alert.addButton(withTitle: localized("Cancel"))
            alert.addButton(withTitle: localized("Empty Bin"))
            alert.buttons[1].hasDestructiveAction = true
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            script("tell application \"Finder\" to empty trash")
        }
    }

    private func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private func script(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { Log.error("quick action: \(error)") }
        }
    }
}
