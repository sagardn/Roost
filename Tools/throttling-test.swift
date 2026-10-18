//
//  throttling-test.swift
//
//  Exercises how macOS's thermal state is shown: the word in the CPU popup
//  and the colour of the CPU figure in the menu bar.
//
//  Run:  cat Roost/UI/Palette.swift Roost/UI/Localized.swift \
//            Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift Roost/Monitor/MenuBarStyle.swift \
//            Roost/Monitor/MenuBarWidget.swift Roost/Monitor/Readings.swift \
//            Roost/Monitor/Throttling.swift Tools/throttling-test.swift | swift -
//
//  The states cannot be produced on demand -- a Mac throttles when it is
//  hot, not when a test asks -- so what is checked is the mapping, every
//  state, both ways round.
//
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias Level = Throttling.Level
typealias Severity = MenuBarReading.Severity

print("macOS's states")
check("nominal is nothing", Level(.nominal) == .none)
check("fair is warm, not throttled", Level(.fair) == .warm)
check("serious is throttled", Level(.serious) == .throttled)
check("critical is severe", Level(.critical) == .severe)
check("the levels are in order", Level.none < .warm && Level.warm < .throttled && Level.throttled < .severe)

print("\nThe word")
check("nothing and warm leave the load's own word", Level.none.verdict == nil && Level.warm.verdict == nil)
check("throttled says so", Level.throttled.verdict == "Throttling")
check("severe says so harder", Level.severe.verdict == "Throttling hard")

print("\nThe colour")
for load in [Severity.calm, .warning, .critical] {
    check("not held back: the load decides (\(load))", Throttling.severity(load: load, .none) == load
          && Throttling.severity(load: load, .warm) == load)
    check("throttled is never calmer than warning (\(load))",
          Throttling.severity(load: load, .throttled) >= .warning
            && Throttling.severity(load: load, .throttled) >= load)
    check("severe is always critical (\(load))", Throttling.severity(load: load, .severe) == .critical)
}
check("a quiet CPU that is being held back is flagged", Throttling.severity(load: .calm, .throttled) == .warning)

print("\nNow")
check("the current state reads without throwing", Level.none <= Throttling.current)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
