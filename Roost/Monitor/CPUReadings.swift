import Foundation
import Darwin

/// Per-core and aggregate processor load.
///
/// `Readings.cpuUsage()` answers the one number the menu bar needs.  This is
/// the detail a popup wants: every logical core separately, and the split
/// between user and system time, which is what tells you whether a machine is
/// busy doing your work or the kernel's.
///
/// `host_processor_info` with `PROCESSOR_CPU_LOAD_INFO` is the public call
/// behind all of it. It reports cumulative ticks since boot, so every figure
/// here is a difference between two samples and the first sample after a
/// start reads nothing.
enum CPUReadings {

    struct CoreLoad {
        /// 0...1, the share of this core's time that was not idle.
        let total: Double
        let user: Double
        let system: Double
    }

    struct Load {
        /// One entry per logical core, in the order the kernel reports them.
        let cores: [CoreLoad]
        let user: Double
        let system: Double
        /// 0...1 across the whole package.
        var total: Double { min(1, user + system) }
    }

    private struct Ticks {
        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
        var busy: UInt32 { user &+ system &+ nice }
        var all: UInt32 { busy &+ idle }
    }

    private static var previous: [Ticks] = []
    private static let lock = NSLock()

    /// nil until a second sample exists, or if the kernel declines to answer.
    static func load() -> Load? {
        guard let now = ticks() else { return nil }

        lock.lock()
        defer { previous = now; lock.unlock() }
        let before = previous
        // A core count that changed under us (or the very first call) makes
        // the difference meaningless.
        guard before.count == now.count, !now.isEmpty else { return nil }

        var cores: [CoreLoad] = []
        var totalUser: Double = 0, totalSystem: Double = 0

        for (index, current) in now.enumerated() {
            let elapsed = current.all &- before[index].all
            guard elapsed > 0 else {
                cores.append(CoreLoad(total: 0, user: 0, system: 0))
                continue
            }
            let divisor = Double(elapsed)
            let user = Double((current.user &- before[index].user)
                              &+ (current.nice &- before[index].nice)) / divisor
            let system = Double(current.system &- before[index].system) / divisor
            cores.append(CoreLoad(total: min(1, user + system), user: user, system: system))
            totalUser += user
            totalSystem += system
        }

        let count = Double(cores.count)
        return Load(cores: cores, user: totalUser / count, system: totalSystem / count)
    }

    /// Resets the baseline, so the next call reports nothing rather than a
    /// difference spanning however long the caller was not looking.
    static func reset() {
        lock.lock()
        previous = []
        lock.unlock()
    }

    // MARK: - The kernel call

    private static func ticks() -> [Ticks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }

        // host_processor_info vends memory the caller owns.
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var result: [Ticks] = []
        result.reserveCapacity(Int(count))

        for core in 0..<Int(count) {
            let base = core * states
            // Defensive: the array length is reported separately from the
            // core count, and reading past it would be a wild pointer.
            guard base + states <= Int(infoCount) else { break }
            result.append(Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Shape of the machine

    /// Logical cores, as the scheduler sees them.
    static var coreCount: Int { ProcessInfo.processInfo.processorCount }

    /// One of the machine's performance levels, as the kernel describes it.
    struct PerfLevel: Equatable {
        /// The `hw.perflevelN` index. 0 is the most performant.
        let index: Int
        /// The kernel's own name for it -- "Performance", "Efficiency".
        /// Not a string this app chose, so a level nobody has seen yet
        /// arrives correctly labelled.
        let name: String
        let logicalCores: Int
    }

    /// Every performance level, ordered the way `host_processor_info` lists
    /// their cores: least performant first.
    ///
    /// Read from `hw.nperflevels` rather than assuming two. Apple silicon
    /// has shipped exactly two since the M1, and the day that changes is the
    /// day a hard-coded pair starts reporting a machine that does not exist
    /// -- this reports whatever the kernel says it has, including one level
    /// on Intel, where the counts are absent and this is empty.
    ///
    /// **The ordering is measured, not assumed.** `hw.perflevel0` is
    /// *Performance* while `host_processor_info` lists *efficiency* cores
    /// first, so the array order is the perflevel index descending. Verified
    /// on an M2 by loading exactly `hw.perflevel0.logicalcpu` threads at
    /// `.userInteractive`, the QoS the scheduler reserves for performance
    /// cores: cores 4-7 took ~285 busy ticks each against 83-123 on cores
    /// 0-3. A three-level machine is the natural extension of that and is
    /// the one case here nobody has been able to run.
    static var perfLevels: [PerfLevel] {
        guard let count = sysctlInt("hw.nperflevels"), count > 0 else { return [] }

        var levels: [PerfLevel] = []
        for index in 0..<count {
            guard let cores = sysctlInt("hw.perflevel\(index).logicalcpu"),
                  cores > 0 else { return [] }
            // A kernel that stops publishing the name is not a reason to
            // drop the level; the count is what the arithmetic needs.
            let name = sysctlString("hw.perflevel\(index).name") ?? "Level \(index)"
            levels.append(PerfLevel(index: index, name: name, logicalCores: cores))
        }
        return levels.reversed()
    }

    /// Efficiency and performance core counts on Apple silicon, nil on Intel
    /// where the distinction does not exist.
    ///
    /// The two-level view of `perfLevels`, kept because that is the shape
    /// every caller wants today. nil rather than a guess where the machine
    /// does not have exactly two levels -- on a future three-level chip the
    /// callers that want a pair get nothing, while `levelLoads` keeps
    /// working.
    static var clusters: (efficiency: Int, performance: Int)? {
        let levels = perfLevels
        guard levels.count == 2 else { return nil }
        return (levels[0].logicalCores, levels[1].logicalCores)
    }

    static var brand: String? { sysctlString("machdep.cpu.brand_string") }

    /// Mean load of each cluster, from the per-core figures. Reported
    /// separately because an M-series machine idling its performance cores
    /// while the efficiency cluster works is the normal, healthy shape, and
    /// one combined number hides it.
    static func clusterLoad(_ cores: [CoreLoad]) -> (efficiency: Double, performance: Double)? {
        let loads = levelLoads(cores)
        guard loads.count == 2 else { return nil }
        return (loads[0].load, loads[1].load)
    }

    /// Mean load of every performance level, least performant first.
    ///
    /// Empty where the levels and the cores disagree, which is the shape a
    /// wrong answer would take: a machine reporting eight cores and levels
    /// adding to six means this code has the wrong model of it, and a mean
    /// over the wrong slice is worse than no figure at all.
    static func levelLoads(_ cores: [CoreLoad]) -> [(level: PerfLevel, load: Double)] {
        let levels = perfLevels
        guard !levels.isEmpty,
              levels.reduce(0, { $0 + $1.logicalCores }) == cores.count else { return [] }

        var result: [(level: PerfLevel, load: Double)] = []
        var start = 0
        for level in levels {
            let slice = cores[start..<(start + level.logicalCores)]
            result.append((level, slice.reduce(0) { $0 + $1.total } / Double(slice.count)))
            start += level.logicalCores
        }
        return result
    }

    /// 1, 5 and 15 minute run-queue averages -- the same figures `uptime`
    /// prints. Not percentages: on an 8-core machine 8.0 means fully
    /// committed, and above that means tasks are queuing.
    static func loadAverage() -> (one: Double, five: Double, fifteen: Double)? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    /// How long since boot.
    static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else {
            return nil
        }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    /// "6 days, 15 hours" -- days and hours, or hours and minutes under a day.
    static func describe(uptime seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600
        if days > 0 {
            return "\(days) day\(days == 1 ? "" : "s"), \(hours) hour\(hours == 1 ? "" : "s")"
        }
        let minutes = (total % 3_600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Thermal limits

    /// What the system is currently doing to the processor to keep it within
    /// its power and thermal budget.
    ///
    /// All three are percentages of full capability except the core count,
    /// which is a count. Every one is optional because macOS reports them
    /// only once it has had cause to: on an idle Mac there is nothing to
    /// report, which is not an error and not a zero.
    struct Limits: Equatable {
        /// How much of the scheduler's capacity processes may have.
        var scheduler: Int?
        /// How many cores are available to schedule on.
        var availableCores: Int?
        /// The clock ceiling, as a percentage of nominal.
        var speed: Int?

        var isEmpty: Bool { scheduler == nil && availableCores == nil && speed == nil }
    }

    /// Reads `pmset -g therm`.
    ///
    /// `pmset` rather than IOKit because this is the documented interface to
    /// it and the figures are not exposed anywhere public otherwise. It is a
    /// subprocess, so it is read off the main thread and sparingly -- these
    /// numbers change when a Mac gets hot, which is minutes, not seconds.
    ///
    /// Measured on an M2: with nothing throttled, the command prints three
    /// "no ... has been recorded" notes and no figures at all. That is the
    /// normal case, and `Limits.isEmpty` is how it reaches the popup.
    static func limits(_ completion: @escaping (Limits) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "therm"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            var output = ""
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                // pmset missing or refused. Nothing to report, which is what
                // an idle Mac reports anyway.
            }
            let limits = parse(therm: output)
            DispatchQueue.main.async { completion(limits) }
        }
    }

    /// Pulls the figures out of what `pmset -g therm` prints.
    ///
    /// Split out so it can be checked against real output, including the
    /// output of a machine with nothing to say -- which is the case that
    /// matters, because treating "not recorded" as zero would have the popup
    /// claiming the processor was limited to nothing.
    static func parse(therm output: String) -> Limits {
        var limits = Limits()
        for line in output.split(separator: "\n") {
            // Lines look like "CPU_Speed_Limit  = 100". A note has no "=".
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch name {
            case "CPU_Scheduler_Limit": limits.scheduler = value
            case "CPU_Available_CPUs":  limits.availableCores = value
            case "CPU_Speed_Limit":     limits.speed = value
            default: break
            }
        }
        return limits
    }

    // MARK: - Frequency

    /// The processor's nominal clock in hertz, where the kernel publishes one.
    ///
    /// `hw.cpufrequency` on Intel. **Absent on Apple silicon** -- measured on
    /// an M2, where that sysctl and `hw.cpufrequency_max` and
    /// `hw.busfrequency` all fail to resolve -- and there is no public
    /// substitute. Live per-cluster frequency there comes from IOReport,
    /// which is a private framework reached through `dlsym`, undocumented,
    /// different per chip generation, and metered by a sampling subscription
    /// that costs power to hold open. Roost does not read it, and the popup
    /// leaves the row out rather than inventing a figure.
    static var nominalFrequency: UInt64? {
        guard let hertz = sysctlInt("hw.cpufrequency"), hertz > 0 else { return nil }
        return UInt64(hertz)
    }

    /// "3.49 GHz", or nil where there is no figure to describe.
    static func describeFrequency() -> String? {
        guard let hertz = nominalFrequency else { return nil }
        return String(format: "%.2f GHz", Double(hertz) / 1_000_000_000)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
