//
//  gesture-test.swift
//
//  Exercises TapRecognizer against synthesised contact frames.
//
//  The trackpad gesture cannot be tested by hand on a machine nobody is
//  sitting at, and a double-tap recogniser has several ways to be subtly
//  wrong: counting a swipe as a tap, joining two different finger counts into
//  one double tap, letting a run survive past its window. Each of those is a
//  case below.
//
//  Run:  cat Roost/Launcher/Gesture.swift Tools/gesture-test.swift | swift -
//
//  The recogniser is compiled in from the app's own source rather than copied,
//  so this cannot drift from what ships.
//
import Foundation

var failures = 0

/// Feeds a gesture: fingers go down, stay down for `held`, then lift.
func tap(_ r: TapRecognizer, fingers: Int, at t: Double, held: Double = 0.08) -> Bool {
    var fired = r.frame(fingers: fingers, at: t)
    fired = r.frame(fingers: fingers, at: t + held / 2) || fired
    fired = r.frame(fingers: 0, at: t + held) || fired
    return fired
}

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

print("TapRecognizer")

// The headline case: a three-finger double tap opens the search.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    check("three-finger double tap fires", !tap(r, fingers: 3, at: 1.0) && tap(r, fingers: 3, at: 1.2))
}

// And so does a four-finger one, with the same settings.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    check("four-finger double tap fires", !tap(r, fingers: 4, at: 1.0) && tap(r, fingers: 4, at: 1.2))
}

// A single tap must not fire, or the gesture would go off while you scroll.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    check("single tap does not fire", !tap(r, fingers: 3, at: 1.0))
}

// Two accepted counts are two separate gestures, not one double tap.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    _ = tap(r, fingers: 3, at: 1.0)
    check("three-finger then four-finger does not fire", !tap(r, fingers: 4, at: 1.2))
}

// ... and the second of those still starts its own run.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    _ = tap(r, fingers: 3, at: 1.0)
    _ = tap(r, fingers: 4, at: 1.2)
    check("the mismatched tap starts a fresh run", tap(r, fingers: 4, at: 1.4))
}

// Too slow is two single taps.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    _ = tap(r, fingers: 3, at: 1.0)
    check("taps outside the double-tap window do not fire", !tap(r, fingers: 3, at: 2.0))
}

// A swipe holds fingers down; it must never read as a tap.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3, 4], taps: 2)
    _ = tap(r, fingers: 3, at: 1.0, held: 0.6)
    check("a held three-finger swipe does not fire", !tap(r, fingers: 3, at: 1.8, held: 0.6))
}

// A count that is switched off is ignored.
do {
    let r = TapRecognizer()
    r.configure(fingers: [4], taps: 2)
    _ = tap(r, fingers: 2, at: 1.0)
    check("a count that is off does not fire", !tap(r, fingers: 2, at: 1.2))
    check("the count that is on does", !tap(r, fingers: 4, at: 2.0) && tap(r, fingers: 4, at: 2.2))
}

// Four fingers landing unevenly still peaks at four.
do {
    let r = TapRecognizer()
    r.configure(fingers: [4], taps: 2)
    func staggered(_ t: Double) -> Bool {
        var f = r.frame(fingers: 2, at: t)
        f = r.frame(fingers: 4, at: t + 0.02) || f
        f = r.frame(fingers: 3, at: t + 0.05) || f
        f = r.frame(fingers: 0, at: t + 0.08) || f
        return f
    }
    check("fingers landing unevenly still count", !staggered(1.0) && staggered(1.2))
}

// An empty set must not disable the gesture outright.
do {
    let r = TapRecognizer()
    r.configure(fingers: [], taps: 2)
    check("an empty set falls back to three, never two", r.acceptedFingers == [3])
}

// Two fingers is gone for good: macOS owns it (secondary click / Smart Zoom)
// and this layer cannot swallow those, so a two-finger search fired both.
do {
    let r = TapRecognizer()
    r.configure(fingers: [2], taps: 2)
    check("two is rejected even when asked for", !r.acceptedFingers.contains(2))
    _ = tap(r, fingers: 2, at: 1.0)
    check("a two-finger double tap never fires", !tap(r, fingers: 2, at: 1.2))
}

// taps: 0 would fire on every frame.
do {
    let r = TapRecognizer()
    r.configure(fingers: [3], taps: 0)
    check("taps is clamped to at least one", r.requiredTaps == 1)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
