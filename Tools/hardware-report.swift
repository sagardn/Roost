//
//  hardware-report.swift
//
//  What this Mac actually answers, reader by reader.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/Readings.swift Roost/Monitor/CPUReadings.swift \
//            Roost/Monitor/MemoryReadings.swift Roost/Monitor/GPUStats.swift \
//            Roost/Monitor/DiskReadings.swift Roost/Monitor/NetworkInfo.swift \
//            Roost/Monitor/Temperature.swift Roost/Monitor/SMCKit.swift \
//            Roost/Monitor/SensorReadings.swift Roost/System/DeviceInfo.swift \
//            Tools/hardware-report.swift | swift -
//
//  Roost is a hardware monitor, and the hardware changes under it. A new
//  Apple silicon generation arrives roughly once a year, and the way this app
//  breaks on one is not a crash -- it is a reading that quietly goes missing,
//  or worse, one that reads zero because a key it expected was not there.
//
//  Nobody can test five generations. This makes a given Mac's coverage a
//  single command, so somebody with an M4 or an M5 can run it and say what
//  their machine answers. It reports a reading as MISSING rather than
//  printing a zero, which is the distinction the whole design rests on.
//
//  Print it and paste it into an issue; that is the whole intended use.
//
import AppKit
import IOKit

setvbuf(stdout, nil, _IONBF, 0)

/// The readers keep their own sysctl helpers private, so this has its own.
func sysctlInteger(_ name: String) -> Int? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var value = 0
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

var present = 0
var missing: [String] = []

/// Reports one reading. nil is "this Mac does not answer", which is a fact
/// about the machine, not a failure -- a Mac with no fans has no fan speed.
func report(_ label: String, _ value: String?, note: String = "") {
    // Padded by hand: a width specifier on %@ is ignored on macOS, which is
    // why the first version of this printed a ragged column.
    let padded = label.padding(toLength: max(34, label.count), withPad: " ",
                               startingAt: 0)
    if let value, !value.isEmpty {
        present += 1
        print("  \(padded) \(value)")
    } else {
        missing.append(label)
        print("  \(padded) MISSING" + (note.isEmpty ? "" : "  (\(note))"))
    }
}

func yesNo(_ condition: Bool) -> String? { condition ? "yes" : nil }
func num(_ value: Int?) -> String? { value.map(String.init) }
func num(_ value: Double?, _ places: Int = 1) -> String? {
    value.map { String(format: "%.\(places)f", $0) }
}

// MARK: - The machine

print("=== Machine ===")
report("model identifier", DeviceInfo.model.identifier)
report("model name", DeviceInfo.model.name)
report("macOS", DeviceInfo.os.version)
report("chip", DeviceInfo.cpu.name)
report("physical cores", num(DeviceInfo.cpu.physicalCores))
report("efficiency cores", num(DeviceInfo.cpu.efficiencyCores),
       note: "Intel reports no core split")
report("performance cores", num(DeviceInfo.cpu.performanceCores),
       note: "Intel reports no core split")
let levels = CPUReadings.perfLevels
report("performance levels", levels.isEmpty ? nil : "\(levels.count)",
       note: "Intel reports none")
for level in levels {
    report("  \(level.name) cores", "\(level.logicalCores)")
}
// Two is what every Apple silicon Mac has shipped with. A third would be
// new hardware, and the app handles it -- but it is worth shouting about,
// because nobody has been able to run this on such a machine.
if levels.count > 2 {
    print("  >> This Mac reports \(levels.count) performance levels. No Mac")
    print("  >> has had more than two. Please send this output in.")
}
report("memory", "\(DeviceInfo.memory / 1_073_741_824) GB")
report("GPU", DeviceInfo.gpu)

// MARK: - CPU

print("\n=== CPU ===")
_ = CPUReadings.load()
usleep(300_000)
if let load = CPUReadings.load() {
    report("per-core load", "\(load.cores.count) cores")
    report("user / system split",
           String(format: "%.0f%% / %.0f%%", load.user * 100, load.system * 100))
    let loads = CPUReadings.levelLoads(load.cores)
    report("per-level load", loads.isEmpty ? nil : loads.map {
        String(format: "%@ %.0f%%", $0.level.name, $0.load * 100)
    }.joined(separator: "   "), note: "levels and cores disagree")
} else {
    report("per-core load", nil)
    report("user / system split", nil)
    report("per-level load", nil)
}
report("load average", CPUReadings.loadAverage().map {
    String(format: "%.2f %.2f %.2f", $0.one, $0.five, $0.fifteen) })
report("uptime", CPUReadings.uptime().map { CPUReadings.describe(uptime: $0) })

// MARK: - Memory

print("\n=== Memory ===")
if let usage = MemoryReadings.usage() {
    report("used / total", "\(usage.used / 1_048_576) MB / \(usage.total / 1_048_576) MB")
    report("app / wired / compressed",
           "\(usage.app / 1_048_576) / \(usage.wired / 1_048_576) / \(usage.compressed / 1_048_576) MB")
} else {
    report("used / total", nil)
    report("app / wired / compressed", nil)
}
report("swap", MemoryReadings.swap().map { "\($0.used / 1_048_576) MB used" })
report("pressure", "\(MemoryReadings.pressure())")

// MARK: - GPU

print("\n=== GPU ===")
let gpus = GPUStats.read()
report("accelerators found", gpus.isEmpty ? nil : "\(gpus.count)")
for gpu in gpus {
    print("  · \(gpu.name)")
    report("    utilization %", num(gpu.utilization),
           note: "driver key not recognised")
    report("    renderer %", num(gpu.renderer), note: "Apple silicon only")
    report("    tiler %", num(gpu.tiler), note: "Apple silicon only")
    report("    GPU memory in use",
           gpu.memoryUsed.map { "\($0 / 1_048_576) MB" },
           note: "not every driver reports it")
}

// The keys themselves, when something did not read. GPUStats looks each
// reading up under several spellings and leaves it nil rather than guessing,
// which is right -- and useless for fixing, because the spelling a new
// driver uses is exactly what nobody has. So print the driver's own key
// list; adding a spelling is then a one-line change.
if gpus.contains(where: { $0.utilization == nil || $0.memoryUsed == nil }) {
    print("\n  A GPU reading is missing. The driver publishes these keys:")
    var iterator = io_iterator_t()
    if IOServiceGetMatchingServices(kIOMainPortDefault,
                                    IOServiceMatching("IOAccelerator"),
                                    &iterator) == KERN_SUCCESS {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any]
            else { continue }
            for key in stats.keys.sorted() {
                print("    \(key) = \(stats[key] ?? "")")
            }
        }
        IOObjectRelease(iterator)
    }
}

// MARK: - Disk

print("\n=== Disk ===")
let volumes = DiskReadings.volumes()
report("browsable volumes", volumes.isEmpty ? nil : "\(volumes.count)")
report("startup volume", DiskReadings.primary().map {
    "\($0.name), \($0.total / 1_073_741_824) GB, \(Int($0.percent * 100))% used" })
let counters = DiskReadings.counters()
report("block devices with counters",
       counters.byDevice.isEmpty ? nil : "\(counters.byDevice.count)",
       note: "IOBlockStorageDriver")

// MARK: - Network

print("\n=== Network ===")
let net = NetworkInfo.current()
report("primary interface", net.primaryInterface)
report("local IP", net.localIP)
report("router", net.router)
report("DNS servers", net.dns.isEmpty ? nil : net.dns.joined(separator: " "))
report("MAC address", net.macAddress)
report("Wi-Fi interface", net.wifiInterface, note: "no Wi-Fi on this Mac")
report("SSID", net.ssid,
       note: net.ssidBlocked ? "blocked: needs Location permission" : "not on Wi-Fi")
report("RSSI", num(net.rssi))
report("Wi-Fi channel", num(net.channel))

// MARK: - Sensors

print("\n=== Sensors ===")
report("AppleSMC reachable", yesNo(SMCKit.shared.isAvailable),
       note: "no SMC: a VM, or a Mac that does not expose one")
report("SMC keys published",
       SMCKit.shared.isAvailable ? "\(SMCKit.shared.allKeys().count)" : nil)

let sensors = SensorReadings.all()
report("sensors after filtering", sensors.isEmpty ? nil : "\(sensors.count)")
for family in ["temperature", "voltage", "current", "power", "fan"] {
    let matching = sensors.filter { "\($0.family)" == family }
    report("  \(family)s", matching.isEmpty ? nil : "\(matching.count)",
           note: family == "fan" ? "a fanless Mac reports none" : "")
}
let hid = sensors.filter { $0.id.hasPrefix("hid:") }
report("HID temperature sensors", hid.isEmpty ? nil : "\(hid.count)",
       note: "IOHIDEventSystemClient")
report("CPU temperature", num(Temperature.cpu()))
report("battery temperature", num(Temperature.battery()), note: "no battery")
report("storage temperature", num(Temperature.storage()))

// MARK: - Verdict

print("\n=== Coverage ===")
print("  \(present) readings answered, \(missing.count) missing")
if !missing.isEmpty {
    print("\n  Missing on this Mac:")
    for label in missing { print("    \(label.trimmingCharacters(in: .whitespaces))") }
    print("""

      A MISSING line is not necessarily a bug. A fanless MacBook Air has no
      fan speed and a desktop has no battery temperature. What matters is
      that the reading is absent rather than zero, and that the app shows a
      dash where it is absent.

      If a line is missing that your Mac plainly has -- a GPU utilization on
      a machine with a GPU, an SSID while on Wi-Fi -- that is the bug worth
      reporting, with this output attached.
    """)
}
