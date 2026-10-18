import Foundation
import Darwin

/// Memory, broken down the way Activity Monitor breaks it down.
///
/// `Readings.memory()` answers used-against-total for the menu bar. This is
/// the detail behind it: where the used half actually went, how much the
/// compressor is holding, and whether the system has started swapping --
/// which is the number that matters, since a machine with high "used" and no
/// swap is fine and one with modest "used" and steady swap is not.
///
/// `host_statistics64` and two sysctls, all public.
enum MemoryReadings {

    struct Usage {
        let total: UInt64
        /// Anonymous pages belonging to running applications.
        let app: UInt64
        /// Pages the kernel cannot page out.
        let wired: UInt64
        /// What the memory compressor is holding, already compressed.
        let compressed: UInt64
        /// File-backed pages the kernel can reclaim on demand. Not pressure.
        let cached: UInt64
        let free: UInt64

        /// What Activity Monitor calls "Memory Used".
        var used: UInt64 { app + wired + compressed }
        var percent: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    struct Swap {
        let total: UInt64
        let used: UInt64
        /// True once the system has actually had to swap, which is the point
        /// at which memory stopped being sufficient.
        var isInUse: Bool { used > 0 }
    }

    enum Pressure: Int {
        case normal = 1, warning = 2, critical = 4

        var label: String {
            switch self {
            case .normal:   return "Normal"
            case .warning:  return "Warning"
            case .critical: return "Critical"
            }
        }
    }

    // MARK: - Usage

    static func usage() -> Usage? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let external = UInt64(stats.external_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page

        // Anonymous resident pages, less anything purgeable -- the kernel can
        // drop purgeable pages without swapping, so counting them as app
        // memory overstates what the machine actually needs.
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let anonymous = active + inactive > external ? active + inactive - external : 0
        let app = anonymous > purgeable ? anonymous - purgeable : anonymous

        return Usage(total: ProcessInfo.processInfo.physicalMemory,
                     app: app,
                     wired: wired,
                     compressed: compressed,
                     cached: external,
                     free: UInt64(stats.free_count) * page)
    }

    // MARK: - Swap

    static func swap() -> Swap? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Swap(total: usage.xsu_total, used: usage.xsu_used)
    }

    // MARK: - Pressure

    /// The kernel's own pressure level, not a figure derived from percentages.
    /// It is what drives the system's own decisions, so it is the honest
    /// answer to "is memory a problem right now".
    static func pressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level",
                           &level, &size, nil, 0) == 0,
              let pressure = Pressure(rawValue: Int(level)) else { return .normal }
        return pressure
    }
}
