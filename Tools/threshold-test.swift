//
//  threshold-test.swift
//
//  Exercises the rule that decides when a reading over its threshold is worth
//  telling somebody about.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/Readings.swift Roost/Monitor/CPUReadings.swift \
//            Roost/Monitor/MemoryReadings.swift Roost/Monitor/Thresholds.swift \
//            Tools/threshold-test.swift | swift -
//
//  All of this is hysteresis and counting, which is the kind of logic that
//  looks obviously right and then fires twice, or never, or once a second for
//  an hour. None of it is visible in a screenshot and none of it can be
//  checked by using the app for five minutes, so it is checked here.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// Feeds a series of readings and returns what the tracker decided for each.
func run(_ values: [Double], threshold: Double = 0.75) -> [ThresholdTracker.Outcome] {
    var tracker = ThresholdTracker()
    return values.map { tracker.check($0, over: threshold) }
}

print("ThresholdTracker")

do {
    check("a quiet machine says nothing",
          run([0.1, 0.2, 0.3, 0.1]).allSatisfy { $0 == .quiet })
}

do {
    // One sample over is a spike -- something launching, a build starting.
    let out = run([0.1, 0.9, 0.1, 0.2])
    check("one sample over does not fire", out.allSatisfy { $0 == .quiet })
}

do {
    let out = run([0.9, 0.9])
    check("two in a row fire, on the second", out == [.quiet, .fire])
}

do {
    let out = run([0.9, 0.9, 0.9, 0.9, 0.9, 0.9])
    check("staying over fires exactly once",
          out.filter { $0 == .fire }.count == 1)
    check("staying over is quiet after that",
          out.dropFirst(2).allSatisfy { $0 == .quiet })
}

do {
    let out = run([0.9, 0.9, 0.5])
    check("coming back under withdraws", out == [.quiet, .fire, .withdraw])
}

do {
    let out = run([0.9, 0.9, 0.5, 0.5, 0.5])
    check("it withdraws once, not on every quiet sample",
          out.filter { $0 == .withdraw }.count == 1)
}

do {
    // The case the hysteresis exists for: a machine hovering at the
    // threshold must not alert on every other sample.
    let out = run([0.9, 0.9, 0.5, 0.9, 0.9, 0.5, 0.9, 0.9])
    check("a reading that goes back and forth fires once per excursion",
          out.filter { $0 == .fire }.count == 3)
    check("and withdraws once per return",
          out.filter { $0 == .withdraw }.count == 2)
}

do {
    // Two over, then under *before* the second sample completes the streak.
    let out = run([0.9, 0.5, 0.9, 0.5])
    check("an interrupted streak starts again rather than accumulating",
          out.allSatisfy { $0 == .quiet })
}

do {
    check("exactly at the threshold counts as over", run([0.75, 0.75]) == [.quiet, .fire])
    check("just under does not", run([0.7499, 0.7499]).allSatisfy { $0 == .quiet })
}

do {
    // A rate reader's first sample divides by a zero interval.
    let out = run([Double.nan, Double.nan, Double.nan])
    check("a reading that is not a number is ignored", out.allSatisfy { $0 == .quiet })

    var tracker = ThresholdTracker()
    _ = tracker.check(0.9, over: 0.75)
    _ = tracker.check(0.9, over: 0.75)
    check("an alert survives a bad sample",
          tracker.check(.nan, over: 0.75) == .quiet && tracker.isShowing)
}

do {
    check("infinity is ignored too",
          run([Double.infinity, Double.infinity]).allSatisfy { $0 == .quiet })
}

do {
    var tracker = ThresholdTracker()
    check("nothing is showing to begin with", !tracker.isShowing)
    _ = tracker.check(0.9, over: 0.75)
    _ = tracker.check(0.9, over: 0.75)
    check("it knows it is showing", tracker.isShowing)
    _ = tracker.check(0.1, over: 0.75)
    check("and knows when it is not", !tracker.isShowing)
}

do {
    // Switching a watch off and on again must not need a dip first.
    var tracker = ThresholdTracker()
    _ = tracker.check(0.9, over: 0.75)
    _ = tracker.check(0.9, over: 0.75)
    tracker.reset()
    check("a reset watch fires again without needing a dip",
          tracker.check(0.9, over: 0.75) == .quiet
          && tracker.check(0.9, over: 0.75) == .fire)
}

do {
    // A threshold of zero means everything is over it. Degenerate, but
    // reachable by hand-editing the settings, and it must not loop.
    let out = run([0, 0, 0], threshold: 0)
    check("a zero threshold fires once and then holds",
          out.filter { $0 == .fire }.count == 1)
}

// MARK: - The settings

print("\nCPUThreshold")

check("there are five watchable readings", CPUThreshold.allCases.count == 5)
check("every one has a name", CPUThreshold.allCases.allSatisfy { !$0.title.isEmpty })
check("the identifiers are the ones already in Notification Centre",
      CPUThreshold.total.notificationID == "Roost_CPU_totalUsage"
      && CPUThreshold.efficiency.notificationID == "Roost_CPU_eCoresUsage")
check("total load is watchable on any Mac", CPUThreshold.total.isAvailable)
check("the cluster readings follow the hardware",
      CPUThreshold.efficiency.isAvailable == (CPUReadings.clusters != nil))

do {
    // Against the real domain, so the keys are the ones that ship -- but
    // every one is put back as it was.
    let key = "CPU_notifications_totalLoad_value"
    let stateKey = "CPU_notifications_totalLoad_state"
    let before = (UserDefaults.standard.object(forKey: key),
                  UserDefaults.standard.object(forKey: stateKey))

    let threshold = CPUThreshold.total
    check("the default is 75%, as it was", threshold.level == 75)
    check("nothing is watched by default", threshold.isWatched == false)

    threshold.level = 83
    check("a percentage stores and reads back", CPUThreshold.total.level == 83)
    check("the threshold is that percentage as a proportion",
          abs(CPUThreshold.total.threshold - 0.83) < 0.0001)

    threshold.level = 500
    check("an impossible percentage is clamped", CPUThreshold.total.level == 100)
    threshold.level = -20
    check("a negative percentage is clamped", CPUThreshold.total.level == 1)

    threshold.isWatched = true
    check("the switch stores", CPUThreshold.total.isWatched)

    UserDefaults.standard.set(before.0, forKey: key)
    UserDefaults.standard.set(before.1, forKey: stateKey)
}

do {
    // The pre-switch form of the setting: one key holding a fraction.
    let legacy = "CPU_notifications_userLoad"
    let stateKey = "CPU_notifications_userLoad_state"
    let valueKey = "CPU_notifications_userLoad_value"
    let before = (UserDefaults.standard.object(forKey: stateKey),
                  UserDefaults.standard.object(forKey: valueKey))

    UserDefaults.standard.set("0.65", forKey: legacy)
    let threshold = CPUThreshold.user
    check("an old threshold is carried over as a percentage", threshold.level == 65)
    check("and as a switch that is on", CPUThreshold.user.isWatched)
    check("and the old key is gone",
          UserDefaults.standard.object(forKey: legacy) == nil)

    UserDefaults.standard.set(before.0, forKey: stateKey)
    UserDefaults.standard.set(before.1, forKey: valueKey)
    UserDefaults.standard.removeObject(forKey: legacy)
}

// MARK: - Watching the other way up

print("\nThresholdTracker, below")

func runBelow(_ values: [Double], threshold: Double = 0.25) -> [ThresholdTracker.Outcome] {
    var tracker = ThresholdTracker()
    return values.map { tracker.check($0, over: threshold, below: true) }
}

check("plenty free says nothing", runBelow([0.9, 0.8, 0.6]).allSatisfy { $0 == .quiet })
check("two samples under fire", runBelow([0.1, 0.1]) == [.quiet, .fire])
check("one dip under does not", runBelow([0.9, 0.1, 0.9]).allSatisfy { $0 == .quiet })
check("coming back up withdraws", runBelow([0.1, 0.1, 0.9]) == [.quiet, .fire, .withdraw])
check("exactly at the threshold counts as under",
      runBelow([0.25, 0.25]) == [.quiet, .fire])
check("staying under fires once",
      runBelow([0.1, 0.1, 0.1, 0.1]).filter { $0 == .fire }.count == 1)

func withClean(_ keys: [String], _ body: () -> Void) {
    let before = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    body()
    for (key, value) in before {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - RAM

print("\nRAMThreshold")

check("there are four watchable readings", RAMThreshold.allCases.count == 4)
check("free is the one that fires on the way down",
      RAMThreshold.allCases.filter({ $0.below }) == [.free])
check("pressure is a level, not a percentage",
      RAMThreshold.pressure.scale == .pressureLevel)
check("swap is a size", RAMThreshold.swap.scale == .megabytes)
check("the identifiers are the ones already in Notification Centre",
      RAMThreshold.total.notificationID == "Roost_RAM_totalUsage"
      && RAMThreshold.swap.notificationID == "Roost_RAM_swap")
check("total's old single key had a different name",
      RAMThreshold.total.legacyKey == "RAM_notifications_totalUsage")

do {
    // Levels are the kernel's own numbers, so one comparison covers all
    // three. A level that is not one of them is not silently kept.
    let pressure = RAMThreshold.pressure
    check("a pressure level is the kernel's number", pressure.clamp(4) == 4)
    check("a nonsense level becomes warning", pressure.clamp(3) == 2)
    check("the threshold is the level itself",
          RAMThreshold.pressure.threshold == Double(RAMThreshold.pressure.level))
}

do {
    let swap = RAMThreshold.swap
    check("swap is clamped to something a Mac could have",
          swap.clamp(10_000_000) == 65_536 && swap.clamp(0) == 64)
    check("a swap threshold is read in bytes",
          RAMThreshold.swap.threshold == Double(RAMThreshold.swap.level) * 1_048_576)
    check("the stepper moves in sensible jumps", swap.step == 64)
}

do {
    check("free reads back as a proportion",
          abs(RAMThreshold.free.threshold - Double(RAMThreshold.free.level) / 100) < 0.0001)
    check("every reading describes itself without crashing",
          RAMThreshold.allCases.allSatisfy { !$0.describe(0.5).isEmpty })
    check("pressure describes itself as a word, not a number",
          RAMThreshold.pressure.describe(4).contains("Critical"))
}

// MARK: - RAM's own migrations

print("\nRAMThreshold migrations")



withClean(["RAM_notifications_pressure_value", "RAM_notifications_pressure_state",
           "RAM_notifications_pressure"]) {
    // The old module stored this as a word. Read as an integer it would come
    // out as zero and quietly become a warning-level alert.
    UserDefaults.standard.set("critical", forKey: "RAM_notifications_pressure_value")
    check("a pressure stored as a word becomes the kernel's level",
          RAMThreshold.pressure.level == 4)
}

withClean(["RAM_notifications_pressure_value", "RAM_notifications_pressure_state",
           "RAM_notifications_pressure"]) {
    UserDefaults.standard.set("warning", forKey: "RAM_notifications_pressure_value")
    check("warning becomes two", RAMThreshold.pressure.level == 2)
}

withClean(["RAM_notifications_swap_value", "RAM_notifications_swap_unit",
           "RAM_notifications_swap_state", "RAM_notifications_swap"]) {
    // 1 GB was the old default, stored as the number 1 and a separate unit.
    UserDefaults.standard.set(1, forKey: "RAM_notifications_swap_value")
    UserDefaults.standard.set("GB", forKey: "RAM_notifications_swap_unit")
    check("a swap threshold in gigabytes becomes megabytes",
          RAMThreshold.swap.level == 1024)
    check("and the unit key is gone",
          UserDefaults.standard.object(forKey: "RAM_notifications_swap_unit") == nil)
}

withClean(["RAM_notifications_swap_value", "RAM_notifications_swap_unit",
           "RAM_notifications_swap_state", "RAM_notifications_swap"]) {
    UserDefaults.standard.set(512, forKey: "RAM_notifications_swap_value")
    UserDefaults.standard.set("MB", forKey: "RAM_notifications_swap_unit")
    check("megabytes are left alone", RAMThreshold.swap.level == 512)
}

withClean(["RAM_notifications_total_value", "RAM_notifications_total_state",
           "RAM_notifications_totalUsage"]) {
    UserDefaults.standard.set("0.9", forKey: "RAM_notifications_totalUsage")
    check("the pre-switch key is carried over under its new name",
          RAMThreshold.total.level == 90 && RAMThreshold.total.isWatched)
    check("and the old key is gone",
          UserDefaults.standard.object(forKey: "RAM_notifications_totalUsage") == nil)
}

// MARK: - GPU

print("\nGPUThreshold")

check("GPU watches one reading", GPUThreshold.allCases.count == 1)
check("the identifier is the one already in Notification Centre",
      GPUThreshold.usage.notificationID == "Roost_GPU_usage")
check("it fires on the way up", !GPUThreshold.usage.below)
check("it is a percentage", GPUThreshold.usage.scale == .percent)

withClean(["GPU_notifications_usage_value", "GPU_notifications_usage_state",
           "GPU_notifications_usage"]) {
    check("the default is 75%, as it was", GPUThreshold.usage.level == 75)
    UserDefaults.standard.set("0.6", forKey: "GPU_notifications_usage")
    check("the pre-switch key is carried over",
          GPUThreshold.usage.level == 60 && GPUThreshold.usage.isWatched)
}

// MARK: - Disk

print("\nDiskThreshold")

check("Disk watches one reading", DiskThreshold.allCases.count == 1)
check("the identifier is the one already in Notification Centre",
      DiskThreshold.utilization.notificationID == "Roost_Disk_usage")
check("the default is 80, later than a processor's",
      DiskThreshold.utilization.defaultValue == 80)

withClean(["Disk_notifications_utilization_value", "Disk_notifications_utilization_state",
           "Disk_notifications_free"]) {
    check("the default reads back", DiskThreshold.utilization.level == 80)
    // The pre-switch key was called `free` even though the number it held
    // was the used share -- so the name has to be overridden, not derived.
    UserDefaults.standard.set("0.92", forKey: "Disk_notifications_free")
    check("the pre-switch key is carried over despite its name",
          DiskThreshold.utilization.level == 92 && DiskThreshold.utilization.isWatched)
    check("and the old key is gone",
          UserDefaults.standard.object(forKey: "Disk_notifications_free") == nil)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
