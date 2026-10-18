import AppKit
import Carbon.HIToolbox

/// Records the keyboard shortcut that opens a module's popup.
///
/// Until this existed the only way to set one was `defaults write` with key
/// codes in a fixed modifier order -- documented, and used by nobody. Click,
/// press the combination, done; ⎋ cancels and ⌫ clears.
///
/// What it stores is exactly what `PopupShortcut.keyCodes(modifiers:keyCode:)`
/// produces from a key press, so a recorded shortcut and a pressed one are
/// built by the same function and cannot disagree about the modifier order.
final class ShortcutRecorder: NSButton {

    let module: String
    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    init(module: String) {
        self.module = module
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { stopRecording() }

    var stored: [UInt16] {
        (UserDefaults.standard.array(forKey: "\(module)_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }

    private func refresh() {
        if recording {
            title = localized("Type shortcut…")
        } else {
            title = stored.isEmpty ? localized("Record Shortcut") : PopupShortcut.display(stored)
        }
        toolTip = localized("Click, then press a combination with ⌃, ⌥ or ⌘. ⎋ cancels, ⌫ clears.")
    }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.handle(event)
            return nil   // swallowed: the key is being recorded, not typed
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            stopRecording()
            return
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            save([])
            stopRecording()
            return
        default:
            break
        }
        guard PopupShortcut.isAcceptable(modifiers: modifiers, keyCode: event.keyCode) else {
            NSSound.beep()
            return
        }
        let codes = PopupShortcut.keyCodes(modifiers: modifiers, keyCode: event.keyCode)
        if let other = PopupShortcut.owner(of: codes, excluding: module) {
            NSSound.beep()
            toolTip = localized("%0 already uses this shortcut", other)
            return
        }
        save(codes)
        stopRecording()
    }

    private func save(_ codes: [UInt16]) {
        if codes.isEmpty {
            UserDefaults.standard.removeObject(forKey: "\(module)_popupShortcut")
        } else {
            UserDefaults.standard.set(codes.map(Int.init), forKey: "\(module)_popupShortcut")
        }
        // The app delegate arms or disarms its keyboard monitor on this --
        // and only arms the global one while some shortcut is set.
        NotificationCenter.default.post(name: .popupKeyboardShortcutChanged, object: nil)
        refresh()
    }
}

/// The keyboard shortcut that opens a module's popup.
///
/// A shortcut is stored as a list of key codes with the modifiers first, in a
/// fixed order, because that is the shape the settings page records when
/// somebody presses a combination. Assembling it the same way on the way back
/// in is the whole of the matching, so the order is load-bearing: a shortcut
/// assembled in a different order never matches the one that was stored, and
/// the symptom is a shortcut that silently does nothing.
enum PopupShortcut {

    /// Virtual key codes for the modifier keys, in the order a stored
    /// shortcut lists them.
    ///
    /// Control, shift, command, option. Not a sorted order and not the order
    /// they appear on the keyboard -- it is the order the recorder wrote, and
    /// it is written down here because it cannot be derived.
    static let control: UInt16 = 59
    static let shift: UInt16 = 60
    static let command: UInt16 = 55
    static let option: UInt16 = 58

    /// The stored form of whatever is currently held down.
    static func keyCodes(modifiers: NSEvent.ModifierFlags,
                         keyCode: UInt16) -> [UInt16] {
        var codes: [UInt16] = []
        if modifiers.contains(.control) { codes.append(control) }
        if modifiers.contains(.shift) { codes.append(shift) }
        if modifiers.contains(.command) { codes.append(command) }
        if modifiers.contains(.option) { codes.append(option) }
        codes.append(keyCode)
        return codes
    }
}

extension PopupShortcut {

    /// Needs ⌃, ⌥ or ⌘. Shift alone is a capital letter, and a plain key
    /// would fire every time somebody typed it -- except the function keys,
    /// which nothing types.
    static func isAcceptable(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        let isModifierKey = [control, shift, command, option, 56, 61, 62, 54].contains(keyCode)
        guard !isModifierKey else { return false }
        if functionKeys.contains(keyCode) { return true }
        return !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                           105, 107, 113, 106, 64, 79, 80, 90]

    /// What already holds exactly this shortcut, if anything: another
    /// module, or one of the launcher's own keys.
    ///
    /// The launcher's keys were not checked before, so a module's popup could
    /// be given ⌃Space and the two would fight for it -- whichever registered
    /// last winning, silently. They are fixed rather than recorded, so they
    /// are listed here; ⌥Tab is the cycle's fallback when another app holds
    /// ⌃Tab, and is reserved whether or not it is in use.
    static func owner(of codes: [UInt16], excluding module: String,
                      defaults: UserDefaults = .standard) -> String? {
        if let reserved = launcherKeys[codes] { return reserved }
        return ["CPU", "GPU", "RAM", "Disk", "Sensors", "Network", "Clipboard"].first { name in
            name != module
                && (defaults.array(forKey: "\(name)_popupShortcut") as? [Int])?.map(UInt16.init) == codes
        }
    }

    /// The launcher's global keys, in the stored form: ⌃Space, ⌃Tab, ⌥Tab,
    /// ⌃` and ⌃1 to ⌃9.
    static let launcherKeys: [[UInt16]: String] = {
        var keys: [[UInt16]: String] = [
            [control, 49]: localized("Search & switcher"),
            [control, 48]: localized("Search & switcher"),
            [option, 48]: localized("Search & switcher"),
            [control, 50]: localized("Search & switcher")
        ]
        // The digit row's key codes, which are not in order.
        for code: UInt16 in [18, 19, 20, 21, 23, 22, 26, 28, 25] {
            keys[[control, code]] = localized("Search & switcher")
        }
        return keys
    }()

    /// "⌃⌥C": the modifiers in the order macOS menus print them, then the key.
    static func display(_ codes: [UInt16], keyName: (UInt16) -> String = keyName(for:)) -> String {
        guard let key = codes.last else { return "" }
        let mods = Set(codes.dropLast())
        let order: [(UInt16, String)] = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")]
        return order.filter { mods.contains($0.0) }.map(\.1).joined() + keyName(key)
    }

    /// A key's name: its own symbol for the keys that have one, otherwise
    /// what the current keyboard layout types on it, so a German layout
    /// shows Z where a US one shows Y.
    static func keyName(for code: UInt16) -> String {
        if let special = specialNames[code] { return special }
        return typed(by: code)?.uppercased() ?? "#\(code)"
    }

    static let specialNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    private static func typed(by code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
