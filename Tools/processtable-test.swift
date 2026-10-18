//
//  processtable-test.swift
//
//  Exercises how the Dashboard's process table is ordered.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/ProcessCPU.swift \
//            Roost/System/DashboardProcesses.swift \
//            Tools/processtable-test.swift | swift -
//
//  Sorting a live table has two traps that only show up while watching it.
//  Rows that tie must not swap places on every refresh, or the table
//  shimmers and cannot be read. And a process whose memory could not be
//  read is not a process using no memory; sorting it as zero puts the
//  unknown at the bottom while claiming it is the smallest.
//
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias Row = DashboardProcesses.Row

func row(_ pid: Int32, _ name: String, _ cpu: Double, _ memory: UInt64?) -> Row {
    Row(pid: pid, name: name, cpu: cpu, memory: memory)
}

let chrome = row(10, "Google Chrome", 42.0, 900_000_000)
let roost  = row(20, "Roost", 2.5, 120_000_000)
let window = row(30, "WindowServer", 12.0, nil)
let agent  = row(40, "agent", 12.0, 50_000_000)
let sample = [roost, chrome, window, agent]

func order(_ sort: DashboardProcesses.Sort) -> [Int32] {
    DashboardProcesses.ordered(sample, by: sort).map(\.pid)
}

print("By processor")
check("the busiest first", order(.cpu).first == 10)
check("the quietest last", order(.cpu).last == 20)
// WindowServer and agent both read 12.0%. Without a tiebreak the order of
// two equal rows is whatever the sort happened to produce, and it can
// differ on the next refresh three seconds later.
check("a tie is broken by pid, so the table does not shimmer",
      order(.cpu) == [10, 30, 40, 20])

print("\nBy memory")
check("the largest first", order(.memory).first == 10)
// The case this exists for: nil is unknown, not zero.
check("memory that could not be read sorts last, not as nothing",
      order(.memory).last == 30)
check("and the rest are in order", order(.memory) == [10, 20, 40, 30])

print("\nBy name")
check("alphabetical, ignoring case",
      order(.name) == [40, 10, 20, 30])

print("\nEvery order keeps every row")
for sort in DashboardProcesses.Sort.allCases {
    check("\(sort.rawValue) loses nobody",
          Set(DashboardProcesses.ordered(sample, by: sort).map(\.pid)) == [10, 20, 30, 40])
}
check("an empty table stays empty",
      DashboardProcesses.ordered([], by: .cpu).isEmpty)

// Sorting by memory has to choose from more than the busiest few, or the
// column does not do what it says: `depth` is read wider than `limit`.
print("\nHow deep the sampler looks")
check("more rows are read than drawn",
      DashboardProcesses.depth > DashboardProcesses.limit)

print("")
if failures == 0 { print("all passed") } else { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
