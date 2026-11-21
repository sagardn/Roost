import Foundation
import CoreAudio
import AudioToolbox

/// The Mac's sound outputs, and switching between them from the search panel.
///
/// CoreAudio's own properties, which are public and need no permission: the
/// device list, each one's name, transport and output streams, and the
/// default output device -- which is what Sound settings' "Output" list sets.
/// The alert sound's device is left alone; macOS ties it to the default
/// unless somebody has deliberately set it apart, and that choice is theirs.
enum AudioOutputs {

    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: Transport
        let isCurrent: Bool

        /// For the row's picture, which is what tells headphones from a
        /// display's speakers before the name is read.
        var symbol: String {
            switch transport {
            case .builtIn:   return "laptopcomputer"
            case .bluetooth: return name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones"
            case .usb:       return "hifispeaker.fill"
            case .display:   return "tv"
            case .airPlay:   return "airplayaudio"
            case .other:     return "speaker.wave.2.fill"
            }
        }
    }

    enum Transport: Equatable {
        case builtIn, bluetooth, usb, display, airPlay, other

        init(_ code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            default: self = .other
            }
        }
    }

    // MARK: - Matching

    /// Words that ask for the outputs themselves. Typed first, they list
    /// every output -- or the ones named by what follows: "sound air".
    static let keywords = ["sound", "audio", "output", "speaker", "speakers", "headphones"]

    /// Outputs for a query, split by where they belong in the panel.
    ///
    /// `primary` answers a query that asks for an output -- a keyword first
    /// -- and goes above the apps, as an action does. `secondary` is a query
    /// that only matches an output's name, which could as easily be the
    /// start of an app's: "mac" is MacBook Air Speakers and also Macs Fan
    /// Control. Those go below the apps, because the panel's first promise
    /// is that a query for an app finds the app first.
    ///
    /// Three letters at least, as for every action. Folded, so "ecouteurs"
    /// finds "Écouteurs".
    static func matching(_ query: String, in devices: [Device]) -> (primary: [Device], secondary: [Device]) {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, fold(query).trimmingCharacters(in: .whitespaces).count >= 3
        else { return ([], []) }

        func named(_ device: Device, by text: String) -> Bool {
            let name = fold(device.name)
            return name.hasPrefix(text)
                || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains { $0.hasPrefix(text) }
        }
        let ordered = { (found: [Device]) in
            found.sorted { a, b in
                a.isCurrent != b.isCurrent ? !a.isCurrent
                    : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        if first.count >= 3, keywords.contains(where: { $0.hasPrefix(first) }) {
            let rest = words.dropFirst().joined(separator: " ")
            return (ordered(rest.isEmpty ? devices : devices.filter { named($0, by: rest) }), [])
        }
        let whole = words.joined(separator: " ")
        return ([], ordered(devices.filter { named($0, by: whole) }))
    }

    // MARK: - CoreAudio

    /// Every output a person can choose: devices with output streams, not
    /// hidden. Asked fresh each time, because headphones come and go.
    static func all() -> [Device] {
        let current = defaultOutput()
        return deviceIDs().compactMap { id in
            guard hasOutput(id), !isHidden(id), let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = Transport(uint32(id, kAudioDevicePropertyTransportType) ?? 0)
            return Device(id: id, name: name, transport: transport, isCurrent: id == current)
        }
    }

    /// Makes `id` the default output. False when CoreAudio refuses.
    @discardableResult
    static func select(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        return status == noErr
    }

    static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        (uint32(id, kAudioDevicePropertyIsHidden) ?? 0) != 0
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        // A Copy-rule property: ours to release, which taking it does.
        return name.takeRetainedValue() as String
    }
}

/// The output's volume and mute, and the microphone's mute.
///
/// The volume is the device's "virtual main" volume -- one number however
/// many channels it has -- which is what the volume keys set. Bluetooth
/// headphones often have no per-channel volume at all, and the main one is
/// the only property every output answers.
enum AudioControl {

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInput() -> AudioDeviceID? {
        var where_ = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    // MARK: Volume

    static func volume() -> Int? {
        guard let device = AudioOutputs.defaultOutput() else { return nil }
        var where_ = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return Int((value * 100).rounded())
    }

    /// Sets the output volume, and unmutes: asking for 30% of a muted output
    /// means wanting to hear it at 30%.
    @discardableResult
    static func setVolume(_ percent: Int) -> Bool {
        guard let device = AudioOutputs.defaultOutput() else { return false }
        var where_ = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value = Float32(min(max(percent, 0), 100)) / 100
        let status = AudioObjectSetPropertyData(device, &where_, 0, nil,
                                                UInt32(MemoryLayout<Float32>.size), &value)
        if status == noErr, percent > 0, isOutputMuted { setMute(device, kAudioObjectPropertyScopeOutput, false) }
        return status == noErr
    }

    // MARK: Mute

    static var isOutputMuted: Bool {
        AudioOutputs.defaultOutput().flatMap { muted($0, kAudioObjectPropertyScopeOutput) } ?? false
    }

    static var isInputMuted: Bool {
        defaultInput().flatMap { muted($0, kAudioObjectPropertyScopeInput) } ?? false
    }

    /// Mutes or unmutes the output; the new state, or nil if this output
    /// cannot be muted.
    static func toggleOutputMute() -> Bool? {
        guard let device = AudioOutputs.defaultOutput() else { return nil }
        let now = !(muted(device, kAudioObjectPropertyScopeOutput) ?? false)
        return setMute(device, kAudioObjectPropertyScopeOutput, now) ? now : nil
    }

    /// The same for the microphone. Not every microphone has a mute switch
    /// CoreAudio can set; for those it says so rather than pretending.
    static func toggleInputMute() -> Bool? {
        guard let device = defaultInput() else { return nil }
        let now = !(muted(device, kAudioObjectPropertyScopeInput) ?? false)
        return setMute(device, kAudioObjectPropertyScopeInput, now) ? now : nil
    }

    static func canMute(input: Bool) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        guard let device = input ? defaultInput() : AudioOutputs.defaultOutput() else { return false }
        var where_ = address(kAudioDevicePropertyMute, scope)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &where_)
            && AudioObjectIsPropertySettable(device, &where_, &settable) == noErr && settable.boolValue
    }

    private static func muted(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool? {
        var where_ = address(kAudioDevicePropertyMute, scope)
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope, _ on: Bool) -> Bool {
        var where_ = address(kAudioDevicePropertyMute, scope)
        guard AudioObjectHasProperty(device, &where_) else { return false }
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &where_, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
