import Foundation
import Darwin
import IOKit.ps

/// System readings: CPU load, memory, disk, network, battery.
///
/// All public APIs — host_statistics, getifaddrs, IOPowerSources — so unlike
/// the temperature reader this needs no private symbols. Rates (CPU, network)
/// are deltas between samples, so the first sample after start reads zero.
enum Readings {

    // MARK: - CPU

    private struct CPUTicks { var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0 }
    private static var lastCPU = CPUTicks()

    private static func cpuTicks() -> CPUTicks? {
        // HOST_CPU_LOAD_INFO_COUNT is a C macro and not visible to Swift
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0),
                        system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2),
                        nice: UInt64(info.cpu_ticks.3))
    }

    /// Busy percentage since the previous call. 0...100.
    static func cpuUsage() -> Double? {
        guard let now = cpuTicks() else { return nil }
        defer { lastCPU = now }
        guard lastCPU.idle != 0 else { return nil }   // first sample has no delta

        let user = now.user &- lastCPU.user
        let system = now.system &- lastCPU.system
        let idle = now.idle &- lastCPU.idle
        let nice = now.nice &- lastCPU.nice
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }

    // MARK: - Memory

    struct Memory { let used: UInt64; let total: UInt64; var percent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 } }

    static func memory() -> Memory? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        // What Activity Monitor calls "memory used": anonymous pages that are
        // resident, plus wired and compressed. Cached/purgeable file pages are
        // not counted, which is why this is not simply total - free.
        let active = UInt64(stats.active_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = active + wired + compressed
        return Memory(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - Disk

    struct Disk { let used: UInt64; let total: UInt64; var percent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 } }

    static func disk() -> Disk? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        let totalBytes = UInt64(total)
        let free = UInt64(max(0, available))
        return Disk(used: totalBytes > free ? totalBytes - free : 0, total: totalBytes)
    }

    // MARK: - Network

    private static var lastRx: UInt64 = 0
    private static var lastTx: UInt64 = 0
    private static var lastNetSample = Date.distantPast

    struct Network { let rxPerSecond: Double; let txPerSecond: Double }

    /// Bytes per second across all real interfaces since the previous call.
    static func network() -> Network? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            // skip loopback and virtual/tunnel interfaces
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"), !name.hasPrefix("bridge"),
                  current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data
            else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(stats.ifi_ibytes)
            tx += UInt64(stats.ifi_obytes)
        }

        let now = Date()
        defer { lastRx = rx; lastTx = tx; lastNetSample = now }
        let elapsed = now.timeIntervalSince(lastNetSample)
        guard lastRx != 0, elapsed > 0, elapsed < 60 else { return nil }

        return Network(rxPerSecond: Double(rx &- lastRx) / elapsed,
                       txPerSecond: Double(tx &- lastTx) / elapsed)
    }

    // MARK: - Battery

    struct Battery { let percent: Double; let charging: Bool; let timeToEmpty: Int? }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let state = info[kIOPSPowerSourceStateKey] as? String
            let minutes = info[kIOPSTimeToEmptyKey] as? Int
            return Battery(percent: Double(current) / Double(max) * 100,
                           charging: state == kIOPSACPowerValue,
                           timeToEmpty: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }

    // MARK: - Formatting

    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value), index = 0
        while size >= 1024, index < units.count - 1 { size /= 1024; index += 1 }
        return String(format: size >= 100 || index == 0 ? "%.0f %@" : "%.1f %@", size, units[index])
    }

    /// A rate, formatted the way a size is.
    ///
    /// The clamp is not tidiness. `UInt64(.infinity)` and `UInt64(.nan)` are
    /// traps, not errors -- they take the process down -- and a rate is a
    /// division by an interval that something else decided was non-zero. The
    /// disk and network readers both refuse to produce one, but this is the
    /// last place before the conversion and the cheapest place to be sure.
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return bytes(0) + "/s" }
        // Above this the figure is meaningless anyway, and the conversion
        // would overflow rather than merely mislead.
        let capped = min(bytesPerSecond, Double(UInt64.max / 2))
        return bytes(UInt64(capped)) + "/s"
    }
}
