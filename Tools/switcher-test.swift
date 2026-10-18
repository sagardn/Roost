//
//  switcher-test.swift
//
//  Exercises the ⌃Tab switcher: the cycle order and the press-by-press walk.
//
//  Reported as "i feel tab swicher have bug". It is not something you can see
//  by reading the code -- the symptoms are an order that changes between
//  cycles and a press that does nothing -- so each one is a case here.
//
//  Run:  cat Roost/Launcher/Recents.swift Tools/switcher-test.swift | swift -
//
//  The logic is compiled in from the app's own source rather than copied, so
//  this cannot drift from what ships.
//
import Foundation
import AppKit

/// Recents talks to WindowControl to raise an app and to drop a cached window
/// state. Neither matters to the ordering, and both need Accessibility, so
/// they are stubbed -- this file is a script, never part of the app target.
enum WindowControl {
    static func invalidateState(_ bundleID: String?) {}
    static func toggleActivateOnly(_ app: NSRunningApplication) {}
}

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print(condition ? "  ok   \(name)" : "  FAIL \(name)")
    if !condition { failures += 1 }
}

/// A stand-in for a running app.
final class FakeApp: Recents.Candidate, CustomStringConvertible {
    let cycleID: String
    var isGone: Bool
    init(_ id: String, gone: Bool = false) { cycleID = id; isGone = gone }
    var description: String { cycleID }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

print("Recents.ordered")

// The app you are in goes last, so one tap lands on the app you came from.
do {
    let apps = [FakeApp("a"), FakeApp("b"), FakeApp("c")]
    let order = Recents.ordered(apps, frontmost: "a",
                                lastUsed: ["a": 30, "b": 20, "c": 10])
    check("frontmost is demoted to last", order.map(\.cycleID) == ["b", "c", "a"])
}

// The bug behind "it jumps around": apps Roost has never seen all scored 0,
// and Swift's sort is not stable, so their order was arbitrary.
do {
    let ids = ["zebra", "apple", "mango", "kiwi", "pear", "fig", "date", "lime"]
    var orders = Set<[String]>()
    for _ in 0..<200 {
        let apps = ids.shuffled().map { FakeApp($0) }
        orders.insert(Recents.ordered(apps, frontmost: nil, lastUsed: [:]).map(\.cycleID))
    }
    check("never-used apps always walk in the same order", orders.count == 1)
}

// Recency still wins over the tiebreak.
do {
    let apps = [FakeApp("apple"), FakeApp("zebra")]
    let order = Recents.ordered(apps, frontmost: nil, lastUsed: ["zebra": 99])
    check("recency beats the alphabetical tiebreak", order.map(\.cycleID) == ["zebra", "apple"])
}

print("Recents.Cycler")

// Tapping repeatedly walks the list and comes back round to where it started.
do {
    var cycler = Recents.Cycler<FakeApp>()
    let list = [FakeApp("b"), FakeApp("c"), FakeApp("a")]
    var visited: [String] = []
    for i in 0..<4 {
        let app = cycler.step(at: t0.addingTimeInterval(Double(i) * 0.3)) { list }
        visited.append(app?.cycleID ?? "nil")
    }
    check("four taps walk b, c, a and round to b", visited == ["b", "c", "a", "b"])
}

// A pause longer than the window starts a new cycle from the top.
do {
    var cycler = Recents.Cycler<FakeApp>()
    var rebuilds = 0
    let list = [FakeApp("b"), FakeApp("a")]
    _ = cycler.step(at: t0) { rebuilds += 1; return list }
    _ = cycler.step(at: t0.addingTimeInterval(0.3)) { rebuilds += 1; return list }
    let after = cycler.step(at: t0.addingTimeInterval(5)) { rebuilds += 1; return list }
    check("a pause rebuilds the list", rebuilds == 2)
    check("and starts again at the first entry", after?.cycleID == "b")
}

// The press that used to do nothing: an app quit while the cycle was open.
do {
    var cycler = Recents.Cycler<FakeApp>()
    let b = FakeApp("b"), c = FakeApp("c"), a = FakeApp("a")
    let list = [b, c, a]
    _ = cycler.step(at: t0) { list }          // -> b
    c.isGone = true                           // c quits mid-cycle
    let next = cycler.step(at: t0.addingTimeInterval(0.3)) { list }
    check("a quit app is stepped over, not landed on", next?.cycleID == "a")
}

// ... and the step past it must not also lose the following app.
do {
    var cycler = Recents.Cycler<FakeApp>()
    let b = FakeApp("b"), c = FakeApp("c"), d = FakeApp("d"), a = FakeApp("a")
    let list = [b, c, d, a]
    _ = cycler.step(at: t0) { list }          // -> b
    c.isGone = true
    var visited: [String] = []
    for i in 1...3 {
        visited.append(cycler.step(at: t0.addingTimeInterval(Double(i) * 0.3)) { list }?.cycleID ?? "nil")
    }
    check("the walk continues correctly after a gap", visited == ["d", "a", "b"])
}

// Everything gone: no crash, nothing activated.
do {
    var cycler = Recents.Cycler<FakeApp>()
    let list = [FakeApp("b", gone: true), FakeApp("a", gone: true)]
    check("an all-quit list returns nothing", cycler.step(at: t0) { list } == nil)
}

// An empty list must not divide by zero.
do {
    var cycler = Recents.Cycler<FakeApp>()
    check("an empty list returns nothing", cycler.step(at: t0) { [] } == nil)
}

// Nothing running but the app you are in: one entry, and it is reachable.
do {
    var cycler = Recents.Cycler<FakeApp>()
    let list = [FakeApp("a")]
    check("a single-entry list still returns it", cycler.step(at: t0) { list }?.cycleID == "a")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
