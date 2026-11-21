//
//  memgrowth-test.swift
//
//  When "keeps using more memory" is said, and when it is not.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/RunawayApps.swift Roost/Monitor/MemoryGrowth.swift \
//            Tools/memgrowth-test.swift | swift -
//
//  An alert that cries wolf is switched off and then misses the real leak,
//  so most of these are cases that must stay quiet. Minutes are fed in as
//  seconds of uptime; no clock is waited on.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let gb: UInt64 = 1 << 30
let mb: UInt64 = 1 << 20

/// Feeds one app's size, a reading a minute, and returns everything said.
func run(_ sizes: [UInt64], app: String = "/Applications/Leaky.app") -> [MemoryGrowth.Detector.Found] {
    var detector = MemoryGrowth.Detector()
    var said: [MemoryGrowth.Detector.Found] = []
    for (minute, bytes) in sizes.enumerated() {
        said += detector.observe([app: bytes], at: TimeInterval(minute * 60))
    }
    return said
}
func climb(from start: UInt64, to end: UInt64, minutes: Int) -> [UInt64] {
    (0...minutes).map { start + (end - start) * UInt64($0) / UInt64(minutes) }
}

print("Said")
let leak = run(climb(from: 2 * gb, to: 4 * gb, minutes: 45))
check("an app that grows from 2 GB to 4 GB in 45 minutes is reported", leak.count == 1)
// Said the first minute all four hold -- thirty minutes in, at about 1.3 GB
// grown -- not at the end of the climb.
check("with how much it had grown", leak.first.map { $0.grownBy >= gb } ?? false)
check("over how long", leak.first.map { $0.minutes >= 30 && $0.minutes <= 45 } ?? false)
check("once, however long it keeps growing",
      run(climb(from: 2 * gb, to: 8 * gb, minutes: 120)).count == 1)

print("\nNot said")
check("an app growing just as fast but still small",
      run(climb(from: 200 * mb, to: 1_900 * mb, minutes: 45)).isEmpty)
check("a large app wobbling by a gigabyte -- large, not growing",
      run((0...60).map { $0 % 2 == 0 ? 20 * gb : 21 * gb }).isEmpty)
check("an app that has only just started and is loading",
      run(climb(from: 100 * mb, to: 3 * gb, minutes: 10)).isEmpty)
check("an app that stays the same size", run(Array(repeating: 6 * gb, count: 90)).isEmpty)

print("\nAgain, later")
var detector = MemoryGrowth.Detector()
var said = 0
let app = "/Applications/Leaky.app"
for (minute, bytes) in climb(from: 2 * gb, to: 4 * gb, minutes: 40).enumerated() {
    said += detector.observe([app: bytes], at: TimeInterval(minute * 60)).count
}
// Quit and reopened: gone from one reading, back small, leaking again.
said += detector.observe([:], at: 41 * 60).count
for (offset, bytes) in climb(from: 2 * gb, to: 4 * gb, minutes: 40).enumerated() {
    said += detector.observe([app: bytes], at: TimeInterval((42 + offset) * 60)).count
}
check("an app that quit and leaks again is reported again", said == 2)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
