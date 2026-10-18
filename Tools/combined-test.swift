//
//  combined-test.swift
//
//  Exercises the combined menu bar item's layout and hit testing.
//
//  Run:  cat Roost/Monitor/CombinedLayout.swift \
//            Tools/combined-test.swift | swift -
//
//  Combined mode draws several modules into one status item. Getting it wrong
//  is close to invisible: a press that opens the module to the left of the one
//  you clicked looks exactly like a press that worked, and a separator counted
//  for a module whose widgets are all off is three points nobody will measure.
//  CombinedLayout is pure arithmetic precisely so this file can hold it to
//  account without a menu bar.
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

typealias M = CombinedLayout.Measurement

// MARK: - Placement

print("CombinedLayout placement")

do {
    let layout = CombinedLayout(of: [])
    check("an empty row is zero wide", layout.width == 0)
    check("an empty row has no slots", layout.slots.isEmpty)
    check("an empty row has nothing to open", layout.slot(atX: 0) == nil)
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32)])
    check("one module starts at the leading edge", layout.slots[0].x == 0)
    check("one module is as wide as its reading", layout.width == 32)
    check("one module takes no separator", layout.rules.isEmpty)
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40), M("Net", 56)])
    check("readings abut with no spacing",
          layout.slots.map({ $0.x }) == [0, 32, 72])
    check("order is the order given",
          layout.slots.map({ $0.name }) == ["CPU", "RAM", "Net"])
    check("width is the sum of the readings", layout.width == 128)
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40)], spacing: 4)
    check("spacing goes between, not around", layout.slots[1].x == 36)
    check("spacing is not added after the last", layout.width == 76)
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40)],
                                spacing: 4, separators: true)
    check("the separator sits in the gap", layout.rules == [.init(x: 36)])
    check("the separator reserves its own footprint", layout.slots[1].x == 43)
    check("width accounts for the separator", layout.width == 83)
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40), M("Net", 56)],
                                separators: true)
    check("one separator per gap, never a trailing one", layout.rules.count == 2)
}

// MARK: - Hit testing

print("\nCombinedLayout hit testing")

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40), M("Net", 56)])
    check("the leading edge opens the first", layout.slot(atX: 0)?.name == "CPU")
    check("inside the first opens the first", layout.slot(atX: 31)?.name == "CPU")
    check("the boundary belongs to the one it starts",
          layout.slot(atX: 32)?.name == "RAM")
    check("inside the last opens the last", layout.slot(atX: 100)?.name == "Net")
    check("past the end still opens the last",
          layout.slot(atX: 999)?.name == "Net")
    check("before the start opens the first",
          layout.slot(atX: -4)?.name == "CPU")
}

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40)],
                                spacing: 4, separators: true)
    check("a press in the gap goes to the module on its left",
          layout.slot(atX: 34)?.name == "CPU")
    check("a press on the separator goes to the module on its left",
          layout.slot(atX: 36)?.name == "CPU")
    check("a press just past the separator goes to the module on its right",
          layout.slot(atX: 43)?.name == "RAM")
}

do {
    // A reading with no width is not in the row, however it got here. Three
    // of them stacked at the same x used to swallow the press meant for the
    // reading beside them, because the hit test takes the last slot starting
    // at or before the press.
    let layout = CombinedLayout(of: [M("CPU", 32), M("GPU", 0), M("RAM", 0), M("Net", 56)],
                                spacing: 4, separators: true)
    check("a reading with no width is not in the row", layout.slots.count == 2)
    check("and takes no separator with it", layout.rules.count == 1)
    check("and cannot swallow its neighbour's press",
          layout.slot(atX: 32)?.name == "CPU" && layout.slot(atX: 43)?.name == "Net")
}

do {
    // The case that mattered: a module whose widgets are all switched off is
    // filtered out before it reaches the layout, so it can neither take a
    // click nor leave a gap where a reading used to be.
    let layout = CombinedLayout(of: [M("CPU", 32), M("Net", 56)], spacing: 4)
    check("a module left out takes no room", layout.width == 92)
    check("a module left out cannot be clicked",
          layout.slots.contains(where: { $0.name == "RAM" }) == false)
    check("what remains closes the gap", layout.slot(atX: 40)?.name == "Net")
}

// MARK: - Spacing setting

print("\nCombinedLayout.spacing(named:)")

check("none is no spacing", CombinedLayout.spacing(named: "none") == 0)
check("small is 2pt", CombinedLayout.spacing(named: "small") == 2)
check("normal is 4pt", CombinedLayout.spacing(named: "normal") == 4)
check("large is 8pt", CombinedLayout.spacing(named: "large") == 8)
check("the numbers the old settings window wrote still read",
      CombinedLayout.spacing(named: "5") == 5)
check("an out-of-range number is clamped", CombinedLayout.spacing(named: "40") == 8)
check("a negative number is clamped", CombinedLayout.spacing(named: "-3") == 0)
check("an unrecognised value is no spacing",
      CombinedLayout.spacing(named: "enormous") == 0)

// MARK: - Slot geometry

print("\nCombinedLayout.Slot")

do {
    let layout = CombinedLayout(of: [M("CPU", 32), M("RAM", 40)], spacing: 4)
    check("maxX is the trailing edge", layout.slots[0].maxX == 32)
    check("slots never overlap",
          zip(layout.slots, layout.slots.dropFirst()).allSatisfy { $0.maxX <= $1.x })
    check("the row is wide enough for the last slot",
          layout.slots.last!.maxX == layout.width)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
