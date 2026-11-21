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
        case .output(let device):
            return device.symbol
        case .keepAwake:
            return "cup.and.saucer.fill"
        case .timer, .cancelTimer:
            return "timer"
        case .volume(let level):
            return level == 0 ? "speaker.slash.fill" : level < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .suggest(_, _, let symbol):
            return symbol
        }
    }

    var title: String {
        switch self {
        case .answer(let title, _): return title
        case .action(let action):   return action.title
        case .output(let device):
            return device.isCurrent ? localized("Playing Through %0", device.name)
                                    : localized("Play Sound Through %0", device.name)
        case .keepAwake(let duration):
            return localized("Keep Mac Awake for %0", KeepAwake.describe(duration))
        case .timer(let seconds, let label):
            let length = KeepAwake.describe(seconds)
            return label.map { localized("Start a %0 Timer: %1", length, $0) }
                ?? localized("Start a %0 Timer", length)
        case .cancelTimer(let id):
            return RoostTimers.shared.timer(id).map {
                localized("Stop Timer (%0)", RoostTimers.describe($0))
            } ?? localized("Stop Timer")
        case .volume(let level):
            return localized("Set Volume to %0%", String(level))
        case .suggest(let title, _, _):
            return title
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
        case .output(let device):
            if device.isCurrent { return }
            Notify.show(AudioOutputs.select(device.id)
                            ? localized("Sound plays through %0", device.name)
                            : localized("Could not switch sound to %0", device.name),
                        symbol: device.symbol)
        case .keepAwake(let duration):
            KeepAwake.shared.turnOn(for: duration)
            guard KeepAwake.shared.isOn, let end = KeepAwake.shared.endsAt else { return }
            Notify.show(localized("The Mac stays awake until %0", KeepAwake.time(end)),
                        symbol: "cup.and.saucer.fill")
        case .timer(let seconds, let label):
            let timer = RoostTimers.shared.start(seconds, label: label)
            Notify.show(localized("Timer set — it ends at %0", KeepAwake.time(timer.endsAt)), symbol: "timer")
        case .cancelTimer(let id):
            RoostTimers.shared.cancel(id)
            Notify.show(localized("Timer stopped"), symbol: "timer")
        case .volume(let level):
            Notify.show(AudioControl.setVolume(level) ? localized("Volume %0%", String(level))
                                                      : localized("This output's volume cannot be set from here"),
                        symbol: symbol)
        case .suggest:
            break    // the panel puts the example in the search field instead
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
        case .keepAwake:
            let on = KeepAwake.shared.toggle()
            Notify.show(on ? localized("The Mac stays awake until you turn this off")
                           : localized("The Mac can sleep again"),
                        symbol: on ? "cup.and.saucer.fill" : "moon.zzz")
        case .ejectAll:
            DiskEject.ejectAll()
        case .pickColor:
            // macOS's own magnifier, which needs no permission: it is the
            // system that reads the screen, and hands back only the colour
            // that was clicked.
            NSColorSampler().show { color in
                guard let hex = color.flatMap(Self.hex) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                Notify.show(localized("Copied %0", hex), symbol: "eyedropper")
            }
        case .muteSound:
            switch AudioControl.toggleOutputMute() {
            case true?:  Notify.show(localized("Sound muted"), symbol: "speaker.slash.fill")
            case false?: Notify.show(localized("Sound is on again"), symbol: "speaker.wave.2.fill")
            case nil:    Notify.show(localized("This output cannot be muted from here"), symbol: "speaker.slash")
            }
        case .muteMic:
            switch AudioControl.toggleInputMute() {
            case true?:  Notify.show(localized("Microphone muted"), symbol: "mic.slash.fill")
            case false?: Notify.show(localized("Microphone is on again"), symbol: "mic.fill")
            case nil:    Notify.show(localized("This microphone cannot be muted from here"), symbol: "mic.slash")
            }
        case .speedTest:
            Notify.show(localized("Testing the internet speed — about 20 seconds"), symbol: "speedometer", for: 3)
            SpeedTest.run { result in
                Notify.show(result.map(SpeedTest.describe)
                                ?? localized("The speed test did not finish — check the connection"),
                            symbol: "speedometer", for: 8)
            }
        case .restart, .shutDown, .logOut:
            guard confirm(self) else { return }
            // System Events, as the Apple menu's own items behave: each app is
            // asked to quit and may stop it to save a document. A restart
            // that force-quit would lose exactly the work that asking is for.
            let verb = self == .restart ? "restart" : self == .shutDown ? "shut down" : "log out"
            script("tell application \"System Events\" to \(verb)")
        case .quitAll:
            let apps = NSWorkspace.shared.runningApplications.filter {
                QuickSearch.Action.quits(bundleID: $0.bundleIdentifier, regular: $0.activationPolicy == .regular,
                           own: Bundle.main.bundleIdentifier)
            }
            guard !apps.isEmpty else {
                Notify.show(localized("No apps to quit"), symbol: "checkmark.circle")
                return
            }
            guard confirm(self, count: apps.count) else { return }
            // Each app's own Quit item, as ⌘Q would: an app with unsaved work
            // asks. Not `terminate()`, whose Apple Event macOS blocks without
            // the Automation permission -- every app stayed open. A beat
            // apart, because pressing the item brings each app forward first
            // and two at once fight over which is in front.
            guard WindowControl.ensureTrusted(for: localized("Quit All Apps")) else { return }
            for (index, app) in apps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) {
                    WindowControl.quit(app)
                }
            }
        }
    }

    /// "#1A2B3C", in sRGB: what a web page or a design file means by a hex
    /// colour. The sampler's colour is in the display's own space, and
    /// written out unconverted it would be a few points off on a wide-gamut
    /// screen.
    static func hex(_ color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(srgb.redComponent),
                      channel(srgb.greenComponent), channel(srgb.blueComponent))
    }

    /// Asks before ending somebody's session, with Cancel as the default so
    /// Return does not restart the Mac by habit.
    private func confirm(_ action: QuickSearch.Action, count: Int = 0) -> Bool {
        let alert = NSAlert()
        switch action {
        case .restart:
            alert.messageText = localized("Restart the Mac?")
            alert.informativeText = localized("Open apps are asked to quit first, and can stop it to save your work.")
        case .shutDown:
            alert.messageText = localized("Shut down the Mac?")
            alert.informativeText = localized("Open apps are asked to quit first, and can stop it to save your work.")
        case .logOut:
            alert.messageText = localized("Log out?")
            alert.informativeText = localized("Open apps are asked to quit first, and can stop it to save your work.")
        default:
            alert.messageText = localized("Quit %0 apps?", String(count))
            alert.informativeText = localized("Each one is asked to quit, so an app with unsaved work will ask first. Finder and Roost stay open.")
        }
        alert.addButton(withTitle: localized("Cancel"))
        alert.addButton(withTitle: action.title)
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    /// Through `osascript`, in its own process. `NSAppleScript` is to be
    /// used on the main thread only, and run there it would hold the search
    /// panel still while Finder empties a full Bin; it ran on a global queue
    /// instead, where two actions chosen in a row ran two at once. A process
    /// has no such rule, and macOS asks once whether Roost may control the
    /// app either way.
    private func script(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    Log.error("quick action: \(String(bytes: message, encoding: .utf8) ?? "status \(process.terminationStatus)")")
                }
            } catch {
                Log.error("quick action: \(error.localizedDescription)")
            }
        }
    }
}
