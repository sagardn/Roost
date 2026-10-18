import Foundation
import IOKit

/// GPU utilization, read straight from the IOKit accelerator registry.
///
/// Every GPU driver on macOS -- AGXAccelerator on Apple Silicon, the AMD and
/// Intel drivers before it -- publishes a `PerformanceStatistics` dictionary
/// under a service inheriting from `IOAccelerator`. The keys inside it differ
/// between drivers, which is why each reading below is looked up under several
/// spellings and left nil rather than guessed at.
///
/// No private symbols and no entitlement: this is the public IORegistry.
enum GPUStats {

    struct Reading {
        let name: String
        /// Overall busy percentage, 0...100.
        let utilization: Double?
        /// Apple Silicon splits the figure; both are nil elsewhere.
        let renderer: Double?
        let tiler: Double?
        /// Bytes of GPU-visible memory in use, where the driver reports it.
        let memoryUsed: UInt64?
    }

    /// One entry per accelerator, in registry order. Empty if none answered.
    static func read() -> [Reading] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var readings: [Reading] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }

            let statistics = properties["PerformanceStatistics"] as? [String: Any] ?? [:]

            readings.append(Reading(
                name: name(of: service, properties: properties),
                utilization: percent(statistics, "Device Utilization %", "GPU Activity(%)",
                                     "Device Utilization", "GPU Core Utilization"),
                renderer: percent(statistics, "Renderer Utilization %", "Renderer Utilization"),
                tiler: percent(statistics, "Tiler Utilization %", "Tiler Utilization"),
                memoryUsed: bytes(statistics, "In use system memory", "inUseVidMemoryBytes",
                                  "Alloc system memory")
            ))
        }
        return readings
    }

    /// The busiest accelerator, which on a machine with both an integrated and
    /// a discrete GPU is the one worth putting in the menu bar.
    static func busiest() -> Reading? {
        read().max { ($0.utilization ?? -1) < ($1.utilization ?? -1) }
    }

    /// How many GPU cores the chip has, where it says.
    ///
    /// `gpu-core-count` on the Apple silicon accelerator. Nothing equivalent
    /// is published for the AMD and Intel drivers, and a shader count is not
    /// the same thing, so this is nil there rather than a number that means
    /// something else. Read once: it cannot change while the Mac is running.
    static let coreCount: Int? = {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "gpu-core-count" as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively
                                                  | kIORegistryIterateParents)),
                  let count = (property as? NSNumber)?.intValue, count > 0
            else { continue }
            return count
        }
        return nil
    }()

    // MARK: - Reading the dictionary

    /// Drivers report these as Int, sometimes as a fraction, sometimes already
    /// a percentage. Anything at or below 1 with a fractional part is treated
    /// as a fraction; everything else is taken at face value and clamped.
    private static func percent(_ statistics: [String: Any], _ keys: String...) -> Double? {
        guard let raw = number(statistics, keys) else { return nil }
        let value = raw <= 1 && raw != raw.rounded() ? raw * 100 : raw
        return min(100, max(0, value))
    }

    private static func bytes(_ statistics: [String: Any], _ keys: String...) -> UInt64? {
        guard let value = number(statistics, keys), value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func number(_ statistics: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = statistics[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }

    private static func name(of service: io_registry_entry_t,
                             properties: [String: Any]) -> String {
        if let model = properties["model"] as? String { return model }
        if let model = properties["model"] as? Data,
           let text = String(data: model, encoding: .utf8)?
               .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
           !text.isEmpty {
            return text
        }
        // The accelerator itself is often unnamed; its parent is the device.
        var parent = io_registry_entry_t()
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var buffer = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(parent, &buffer) == KERN_SUCCESS {
                let text = String(cString: buffer)
                if !text.isEmpty { return text }
            }
        }
        return "GPU"
    }
}
