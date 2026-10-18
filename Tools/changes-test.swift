//
//  changes-test.swift
//
//  Exercises the rule that decides when something has really changed.
//
//  Run:  cat Roost/Monitor/Changes.swift Tools/changes-test.swift | swift -
//
//  A connectivity probe through a link that is already struggling fails
//  occasionally without the link being down, and a public address read
//  through one comes back wrong now and then. The difference between
//  noticing that and crying wolf is a counter, and a counter is exactly the
//  kind of thing that looks right and fires on the first flicker.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// Feeds a series and returns what the tracker decided for each.
func run<T: Equatable>(_ values: [T], confirmations: Int = 1) -> [ChangeTracker<T>.Change?] {
    var tracker = ChangeTracker<T>(confirmations: confirmations)
    return values.map { tracker.check($0) }
}

print("ChangeTracker")

do {
    // Starting the app is not an event. Reporting the first value seen would
    // mean an alert every launch for every watch that is on.
    let out = run(["en0"])
    check("the first value seen is never a change", out[0] == nil)
}

do {
    let out = run(["en0", "en0", "en0"])
    check("nothing changing says nothing", out.allSatisfy { $0 == nil })
}

do {
    let out = run(["en0", "en1"])
    check("a change is reported once", out.compactMap({ $0 }).count == 1)
    check("and says what it was and what it is now",
          out[1]?.from == "en0" && out[1]?.to == "en1")
}

do {
    let out = run(["en0", "en1", "en1", "en1"])
    check("a change that sticks is reported once, not every sample",
          out.compactMap({ $0 }).count == 1)
}

do {
    let out = run([true, false, true, false])
    check("a value flapping is reported each time it moves",
          out.compactMap({ $0 }).count == 3)
}

// MARK: - Confirmation

print("\nChangeTracker, with confirmation")

do {
    // Two in a row, which is what the connection watch waits for.
    let out = run([true, false, false], confirmations: 2)
    check("one disagreeing sample is not a change", out[1] == nil)
    check("two in a row is", out[2]?.to == false)
}

do {
    let out = run([true, false, true, false, true], confirmations: 2)
    check("a value that flickers back is never reported",
          out.allSatisfy { $0 == nil })
}

do {
    // Three, which is what the public address watch waits for.
    let out = run(["1.1.1.1", "2.2.2.2", "2.2.2.2", "2.2.2.2"], confirmations: 3)
    check("two agreeing samples are not enough", out[1] == nil && out[2] == nil)
    check("three are", out[3]?.to == "2.2.2.2")
    check("and the change is from the value it actually had",
          out[3]?.from == "1.1.1.1")
}

do {
    // The streak must count agreement with the *new* answer, not merely
    // disagreement with the old one -- otherwise two different wrong
    // readings would add up to a change that never happened.
    let out = run(["1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4"], confirmations: 3)
    check("three different wrong answers do not make a change",
          out.allSatisfy { $0 == nil })
}

do {
    var tracker = ChangeTracker<String>(confirmations: 2)
    _ = tracker.check("a")
    _ = tracker.check("b")
    _ = tracker.check("a")        // back to where it was; streak must clear
    check("returning to the known value clears the streak",
          tracker.check("b") == nil)
}

// MARK: - Housekeeping

print("\nChangeTracker housekeeping")

do {
    var tracker = ChangeTracker<String>()
    check("it knows it has no baseline", !tracker.hasBaseline)
    _ = tracker.check("en0")
    check("and that it has one", tracker.hasBaseline)
    tracker.reset()
    check("a reset forgets it", !tracker.hasBaseline)
    check("so the next value is adopted rather than reported",
          tracker.check("en9") == nil)
}

do {
    check("a confirmation count below one is treated as one",
          ChangeTracker<String>(confirmations: 0).confirmations == 1)
    check("and a negative one too",
          ChangeTracker<String>(confirmations: -5).confirmations == 1)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
