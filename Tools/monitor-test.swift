//
//  monitor-test.swift
//
//  Exercises the independent monitor's readers.
//
//  Run:  cat Roost/Monitor/ProcessNetwork.swift \
//            Roost/Monitor/ProcessCPU.swift Roost/Monitor/ProcessMemory.swift \
//            Roost/Monitor/CPUReadings.swift \
//            Roost/Monitor/MemoryReadings.swift \
//            Tools/monitor-test.swift | swift -
//
//  The readers are compiled in from the app's own source rather than copied,
//  so this cannot drift from what ships. Everything here is either a pure
//  function (the nettop parser) or an invariant that must hold on any Mac --
//  no fixture can stand in for the kernel, but "a percentage is between 0 and
//  1" is checkable anywhere.
//
import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

// MARK: - ProcessNetwork.parse

print("ProcessNetwork.parse")

do {
    let counts = ProcessNetwork.parse("""
    time,bytes_in,bytes_out,
    Google Chrome.481,12345,678,
    """)
    check("a well-formed row is read", counts[481]?.received == 12345 && counts[481]?.sent == 678)
    check("the header row is ignored", counts.count == 1)
}

do {
    // The name itself contains dots, which is why the pid is split off the
    // end rather than the name off the front.
    let counts = ProcessNetwork.parse("io.tailscale.ip.4821,900,100,\n")
    check("a dotted process name keeps its pid", counts[4821]?.received == 900)
}

do {
    let counts = ProcessNetwork.parse("""
    Safari.22,10,1,
    Safari.22,5,2,
    """)
    check("a pid listed twice is summed",
          counts[22]?.received == 15 && counts[22]?.sent == 3)
}

do {
    let counts = ProcessNetwork.parse("""
    rubbish
    ,,,
    NoPid,1,2,
    Trailing.99,notanumber,2,
    """)
    check("malformed rows are dropped, not guessed at", counts.isEmpty)
}

do {
    check("empty input yields nothing", ProcessNetwork.parse("").isEmpty)
}

// MARK: - CPUReadings

print("\nCPUReadings")

check("the machine reports at least one core", CPUReadings.coreCount >= 1)
check("the processor has a name", (CPUReadings.brand ?? "").isEmpty == false)

do {
    CPUReadings.reset()
    check("the first sample has nothing to difference against", CPUReadings.load() == nil)

    Thread.sleep(forTimeInterval: 0.3)
    guard let load = CPUReadings.load() else {
        check("a second sample produces a reading", false)
        exit(1)
    }
    check("a second sample produces a reading", true)
    check("one entry per logical core", load.cores.count == CPUReadings.coreCount)
    check("every core is within 0...1", load.cores.allSatisfy { $0.total >= 0 && $0.total <= 1 })
    check("the total is within 0...1", load.total >= 0 && load.total <= 1)
    check("user and system are not negative", load.user >= 0 && load.system >= 0)
}

do {
    // A cluster split is Apple silicon only; on Intel nil is the right answer.
    if let clusters = CPUReadings.clusters {
        check("clusters add up to the core count",
              clusters.efficiency + clusters.performance == CPUReadings.coreCount)
    } else {
        check("no cluster split reported (Intel, or unavailable)", true)
    }
}

// MARK: - CPU detail

print("\nCPUReadings detail")

do {
    CPUReadings.reset()
    _ = CPUReadings.load()
    Thread.sleep(forTimeInterval: 0.3)
    guard let load = CPUReadings.load() else {
        check("a reading is available", false); exit(1)
    }
    check("a reading is available", true)
    check("user and system sum to the total",
          abs((load.user + load.system) - load.total) < 0.001 || load.total == 1)

    // MARK: Performance levels, read rather than assumed

    do {
        let levels = CPUReadings.perfLevels
        let count = CPUReadings.coreCount

        if levels.isEmpty {
            check("no performance levels on this machine, so no cluster split",
                  CPUReadings.clusters == nil)
        } else {
            check("the levels account for every logical core "
                  + "(\(levels.map { $0.logicalCores }.reduce(0, +)) of \(count))",
                  levels.reduce(0) { $0 + $1.logicalCores } == count)
            check("every level is named by the kernel, not by us "
                  + "(\(levels.map { $0.name }.joined(separator: ", ")))",
                  levels.allSatisfy { !$0.name.isEmpty })
            check("every level has at least one core",
                  levels.allSatisfy { $0.logicalCores > 0 })
            // perfLevels is reversed so the array matches the order
            // host_processor_info lists cores in: least performant first.
            check("levels run least-performant first",
                  levels.map { $0.index } == levels.map { $0.index }.sorted(by: >))

            let loads = CPUReadings.levelLoads(load.cores)
            check("a load for every level", loads.count == levels.count)
            check("every level load is a share",
                  loads.allSatisfy { $0.load >= 0 && $0.load <= 1 })
            check("every level load is a number",
                  loads.allSatisfy { $0.load.isFinite })

            // The two-level accessor is the general one narrowed, so the two
            // must agree wherever both answer. This is the assertion that
            // catches the general version being wired up backwards.
            if levels.count == 2, let pair = CPUReadings.clusterLoad(load.cores) {
                check("clusterLoad agrees with levelLoads on efficiency",
                      abs(pair.efficiency - loads[0].load) < 0.0001)
                check("and on performance",
                      abs(pair.performance - loads[1].load) < 0.0001)
                check("the efficiency cluster is the one the kernel calls that",
                      loads[0].level.name.lowercased().contains("efficien"))
                check("and the performance cluster likewise",
                      loads[1].level.name.lowercased().contains("perform"))
            } else {
                check("clusterLoad declines where there are not exactly two levels",
                      CPUReadings.clusterLoad(load.cores) == nil)
            }
        }
    }

    // A machine whose levels do not add up to its cores is one this code has
    // the wrong model of, and a mean over the wrong slice is worse than no
    // figure. Checked with a core list of the wrong length.
    do {
        let tooFew = Array(load.cores.prefix(max(0, load.cores.count - 1)))
        check("a core list that does not match the levels gets no split",
              CPUReadings.levelLoads(tooFew).isEmpty)
        let tooMany = load.cores + load.cores
        check("nor does one with too many",
              CPUReadings.levelLoads(tooMany).isEmpty)
        check("nor does an empty one", CPUReadings.levelLoads([]).isEmpty)
    }

    if let clusters = CPUReadings.clusterLoad(load.cores) {
        check("cluster loads are within 0...1",
              clusters.efficiency >= 0 && clusters.efficiency <= 1
                && clusters.performance >= 0 && clusters.performance <= 1)
    } else {
        check("no cluster split on this machine", CPUReadings.clusters == nil)
    }
}

do {
    guard let average = CPUReadings.loadAverage() else {
        check("load average is readable", false); exit(1)
    }
    check("load average is readable", true)
    check("all three windows are non-negative",
          average.one >= 0 && average.five >= 0 && average.fifteen >= 0)
}

do {
    guard let uptime = CPUReadings.uptime() else {
        check("uptime is readable", false); exit(1)
    }
    check("uptime is readable", true)
    check("uptime is positive", uptime > 0)
    check("a day and a half reads as days and hours",
          CPUReadings.describe(uptime: 86_400 * 1.5) == "1 day, 12 hours")
    check("under a day reads as hours and minutes",
          CPUReadings.describe(uptime: 3_600 * 2 + 60 * 5) == "2h 5m")
}

// MARK: - ProcessCPU.percent

print("\nProcessCPU.percent")

// This replaced parsing `ps`, which cost 98 ms a refresh against 0.8 ms for
// a native sweep -- about 10% of a core for as long as the CPU popup was
// open, which is why Roost was the top entry in its own list.
check("a second of CPU over a second is one core",
      ProcessCPU.percent(before: 0, after: 1_000_000_000, elapsed: 1) == 100)
check("two cores' worth reads over 100%",
      ProcessCPU.percent(before: 0, after: 2_000_000_000, elapsed: 1) == 200)
check("half a second over a second is 50%",
      ProcessCPU.percent(before: 0, after: 500_000_000, elapsed: 1) == 50)
check("an idle process reads zero",
      ProcessCPU.percent(before: 5_000_000_000, after: 5_000_000_000, elapsed: 1) == 0)
check("the elapsed time divides",
      ProcessCPU.percent(before: 0, after: 1_000_000_000, elapsed: 2) == 50)

// nil, never zero, when the answer cannot be trusted.
check("no time passed: no answer",
      ProcessCPU.percent(before: 0, after: 1_000_000_000, elapsed: 0) == nil)
check("time going backwards: no answer",
      ProcessCPU.percent(before: 0, after: 1_000_000_000, elapsed: -1) == nil)
// A pid is reused by a different process, whose CPU time starts lower.
check("the counter going backwards means the pid was reused",
      ProcessCPU.percent(before: 9_000_000_000, after: 1_000_000, elapsed: 1) == nil)

// MARK: - MemoryReadings

print("\nMemoryReadings")

do {
    guard let usage = MemoryReadings.usage() else {
        check("memory can be read", false)
        exit(1)
    }
    check("memory can be read", true)
    check("physical memory is plausible", usage.total > 1_000_000_000)
    check("used does not exceed physical", usage.used <= usage.total)
    check("the percentage is within 0...1", usage.percent >= 0 && usage.percent <= 1)
    check("used is the sum of its parts",
          usage.used == usage.app + usage.wired + usage.compressed)
    // Cached and free are reclaimable rather than used, so the whole set
    // should still fit inside physical memory.
    check("the parts fit inside physical memory",
          usage.app + usage.wired + usage.compressed + usage.cached + usage.free
            <= usage.total + usage.total / 10)
}

do {
    if let swap = MemoryReadings.swap() {
        check("swap used does not exceed swap size", swap.used <= swap.total)
        check("isInUse agrees with the figure", swap.isInUse == (swap.used > 0))
    } else {
        check("swap is unavailable on this machine", true)
    }
}

do {
    let pressure = MemoryReadings.pressure()
    check("pressure is one of the kernel's own levels",
          [.normal, .warning, .critical].contains(pressure))
}

// MARK: - ProcessMemory.parse

print("\nProcessMemory.parse")

do {
    let listing = """
      PID    RSS COMM
    91363 421760 claude
    30460 370240 Google Chrome Helper (Aperitif Renderer)
      123      0 idled
    """
    let entries = ProcessMemory.parse(listing, limit: 10)
    check("the header row is ignored", entries.count == 2)
    check("kilobytes become bytes", entries[0].bytes == 421_760 * 1024)
    check("a name with spaces and brackets survives",
          entries[1].name == "Google Chrome Helper (Aperitif Renderer)")
    check("a process holding nothing is not a row",
          !entries.contains { $0.pid == 123 })
    check("the order ps gave is kept",
          entries.map({ $0.pid }) == [91363, 30460])
}

do {
    let listing = """
      PID    RSS COMM
    1 100 a
    2 90 b
    3 80 c
    """
    check("the limit is honoured", ProcessMemory.parse(listing, limit: 2).count == 2)
    check("no rows is not a crash", ProcessMemory.parse("", limit: 5).isEmpty)
    check("a malformed line is skipped",
          ProcessMemory.parse("PID RSS COMM\nnonsense", limit: 5).isEmpty)
}

// MARK: - CPUReadings.parse(therm:)

print("\nCPUReadings.parse(therm:)")

do {
    // What pmset prints on a Mac that is being held back.
    let limited = """
    Note: No thermal warning level has been recorded
    CPU_Scheduler_Limit \t= 62
    CPU_Available_CPUs \t= 4
    CPU_Speed_Limit \t= 75
    """
    let limits = CPUReadings.parse(therm: limited)
    check("the scheduler limit is read", limits.scheduler == 62)
    check("the available core count is read", limits.availableCores == 4)
    check("the clock ceiling is read", limits.speed == 75)
    check("a populated reading is not empty", !limits.isEmpty)
}

do {
    // The normal case, measured on an idle M2: three notes and no figures.
    // Reading these as zero would have the popup reporting a processor
    // limited to nothing at all.
    let idle = """
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    Note: No CPU power status has been recorded
    """
    check("nothing recorded is nothing reported",
          CPUReadings.parse(therm: idle).isEmpty)
    check("no output at all is nothing reported",
          CPUReadings.parse(therm: "").isEmpty)
}

do {
    check("a line with no value is skipped",
          CPUReadings.parse(therm: "CPU_Speed_Limit \t= \nCPU_Available_CPUs = 8")
            .availableCores == 8)
    check("a name we do not know is skipped",
          CPUReadings.parse(therm: "GPU_Speed_Limit = 50").isEmpty)
    check("a value that is not a number is skipped",
          CPUReadings.parse(therm: "CPU_Speed_Limit = some").isEmpty)
}

do {
    // Nominal frequency exists on Intel and does not on Apple silicon.
    // Either answer is correct; claiming one on a Mac that has none is not.
    if let clock = CPUReadings.describeFrequency() {
        check("a described clock is in GHz", clock.hasSuffix(" GHz"))
    } else {
        check("this Mac publishes no nominal clock, and none is claimed",
              CPUReadings.nominalFrequency == nil)
    }
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
