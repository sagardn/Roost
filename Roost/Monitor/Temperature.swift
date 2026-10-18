import Foundation

/// Reads Apple Silicon temperature sensors.
///
/// The old SMC keys (TC0P and friends) return nothing on Apple Silicon. The
/// working route is IOHIDEventSystemClient filtered to the Apple vendor
/// temperature page, which needs no privileges and no sudo. The page/usage
/// and event-type constants below are the HID event system's own values for
/// that page; nothing public names them.
///
/// These are private IOKit symbols, so they are resolved with dlsym rather
/// than linked, and every one is checked before use.
enum Temperature {

    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 0x0005
    private static let eventTypeTemperature: Int32 = 15

    private typealias CreateClient  = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching   = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices  = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyProperty  = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent     = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private struct Symbols {
        let create: CreateClient
        let match: SetMatching
        let services: CopyServices
        let property: CopyProperty
        let event: CopyEvent
        let value: GetFloatValue
    }

    private static let symbols: Symbols? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(iokit, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = load("IOHIDEventSystemClientCreate", CreateClient.self),
              let match = load("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let services = load("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let property = load("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let event = load("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let value = load("IOHIDEventGetFloatValue", GetFloatValue.self)
        else { return nil }
        return Symbols(create: create, match: match, services: services,
                       property: property, event: event, value: value)
    }()

    static var isAvailable: Bool { symbols != nil }

    /// Every sensor, as name -> degrees Celsius.
    static func readAll() -> [(name: String, celsius: Double)] {
        guard let s = symbols, let client = s.create(kCFAllocatorDefault) else { return [] }
        _ = s.match(client, ["PrimaryUsagePage": appleVendorPage,
                             "PrimaryUsage": temperatureUsage] as CFDictionary)
        guard let list = s.services(client)?.takeRetainedValue() as? [AnyObject] else { return [] }

        var readings: [(String, Double)] = []
        for entry in list {
            let service = Unmanaged.passUnretained(entry).toOpaque()
            guard let nameRef = s.property(service, "Product" as CFString),
                  let name = nameRef.takeRetainedValue() as? String,
                  let event = s.event(service, Int64(eventTypeTemperature), 0, 0)
            else { continue }
            readings.append((name, s.value(event, eventTypeTemperature << 16)))
        }
        return readings
    }

    private static func plausible(_ celsius: Double) -> Bool {
        celsius > 0 && celsius < 120
    }

    /// CPU/SoC temperature: the mean of the die sensors.
    ///
    /// Only `tdie` sensors are used. `tcal` is a fixed calibration reference
    /// that sits ~8 degrees high, and several `tdev` sensors report -1.6 when
    /// unused, so averaging everything would be meaningfully wrong.
    static func cpu() -> Double? {
        let die = readAll()
            .filter { $0.name.lowercased().contains("tdie") && plausible($0.celsius) }
            .map(\.celsius)
        guard !die.isEmpty else { return nil }
        return die.reduce(0, +) / Double(die.count)
    }

    /// Hottest die sensor, which is what throttling actually tracks.
    static func cpuPeak() -> Double? {
        readAll()
            .filter { $0.name.lowercased().contains("tdie") && plausible($0.celsius) }
            .map(\.celsius)
            .max()
    }

    static func battery() -> Double? {
        readAll()
            .filter { $0.name.lowercased().contains("gas gauge") && plausible($0.celsius) }
            .map(\.celsius)
            .max()
    }

    static func storage() -> Double? {
        readAll()
            .filter { $0.name.lowercased().contains("nand") && plausible($0.celsius) }
            .map(\.celsius)
            .max()
    }
}
