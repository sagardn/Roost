import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Carbon is used rather than an NSEvent global monitor or a CGEventTap
/// because it does not require Accessibility permission -- so the hotkeys
/// still work if the user has not granted it yet (they get a HUD explaining
/// what is missing instead of silence).
final class Hotkey {

    /// Virtual key codes (HIToolbox Events.h).
    enum Key {
        static let space: UInt32 = 49
        static let grave: UInt32 = 50   // the ` / ~ key
        static let semicolon: UInt32 = 41
        static let tab: UInt32 = 48

        /// Maps a single character from the config file to a virtual key code.
        /// Only the characters that make sense as an app shortcut.
        static func code(for character: String) -> UInt32? {
            switch character.lowercased() {
            case "1": return 18
            case "2": return 19
            case "3": return 20
            case "4": return 21
            case "5": return 23
            case "6": return 22
            case "7": return 26
            case "8": return 28
            case "9": return 25
            case "0": return 29
            case "`": return grave
            case ";": return 41
            case "space": return space
            default:   return nil
            }
        }
    }

    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let option  = Modifiers(rawValue: UInt32(optionKey))
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let shift   = Modifiers(rawValue: UInt32(shiftKey))
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false
    private var reference: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: Modifiers, action: @escaping () -> Void) {
        Hotkey.installEventHandlerIfNeeded()

        id = Hotkey.nextID
        Hotkey.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x50524348), id: id)  // 'PRCH'
        let status = RegisterEventHotKey(keyCode,
                                         modifiers.rawValue,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, reference != nil else {
            // -9878 (eventHotKeyExistsErr) means another app already owns it.
            NSLog("Roost: hotkey keyCode \(keyCode) not registered (OSStatus \(status))")
            return nil
        }
        Hotkey.handlers[id] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Hotkey.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            guard status == noErr, let action = Hotkey.handlers[id.id] else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
