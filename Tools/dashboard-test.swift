//
//  dashboard-test.swift
//
//  Exercises the Dashboard's decisions: the stored card layout, the rules
//  that turn module readings into issues, the macOS release names, the
//  serial mask and the uptime wording.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Palette.swift \
//            Roost/System/DashboardLogic.swift Roost/System/DeviceInfo.swift \
//            Roost/System/BatteryHealth.swift Roost/Monitor/Readings.swift \
//            Tools/dashboard-test.swift | swift -
//
//  Each of these is a place where the page could say something untrue
//  without anything failing: a stored layout from an older release that
//  hides a new card, a 60% CPU reported as a problem, a release called by
//  the last name the table knew. The rules are compiled in from the app's
//  own source, so they cannot drift from what ships.
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

// MARK: - Layout

print("Layout")

let standard = DashboardLayout.standard
check("nothing stored is the standard layout",
      DashboardLayout.resolve(order: nil, hidden: nil) == standard)
check("the standard layout shows the primary cards, in order",
      standard.visible == [.cpu, .memory, .disk, .network, .battery])
check("GPU and Sensors start hidden", standard.hidden == [.gpu, .sensors])

let stored: DashboardLayout = .resolve(order: ["Disk", "CPU", "RAM", "Network", "GPU", "Sensors"],
                                       hidden: ["CPU"])
check("a stored order is kept, and the battery card added after it arrives after Network",
      stored.order == [.disk, .cpu, .memory, .network, .battery, .gpu, .sensors])
check("a layout stored before the battery card shows it", !stored.hidden.contains(.battery))
check("a stored hidden list is kept exactly", stored.hidden == [.cpu])
check("a card the user showed stays shown", stored.visible.contains(.gpu))

// Not "Battery": that was the unknown name here until the battery card made
// it a known one.
let unknown: DashboardLayout = .resolve(order: ["Clock", "RAM", "RAM", "CPU"], hidden: ["Bluetooth"])
check("an unknown name is dropped, a duplicate collapses, the stored order holds",
      unknown.order.first == .memory
      && unknown.order.firstIndex(of: .memory)! < unknown.order.firstIndex(of: .cpu)!)
check("every card is still there after a bad list",
      Set(unknown.order) == Set(DashboardCard.allCases) && unknown.order.count == DashboardCard.allCases.count)
check("an unknown hidden name is ignored", !unknown.hidden.contains(where: { $0.rawValue == "Bluetooth" }))

// A layout saved before Sensors existed: Sensors is new to it, so it takes
// its default place and its default visibility.
let older: DashboardLayout = .resolve(order: ["CPU", "RAM", "Disk", "Network", "GPU"], hidden: [])
check("a card newer than the stored layout is inserted after its default neighbour",
      older.order == [.cpu, .memory, .disk, .network, .battery, .gpu, .sensors])
check("and takes its default visibility", older.hidden == [.sensors])
check("while a stored card keeps the visibility it was given", !older.hidden.contains(.gpu))

let reordered: DashboardLayout = .resolve(order: ["Network", "Disk"], hidden: nil)
check("missing cards that precede everything go to the front",
      reordered.order.first == .cpu)
check("and the stored ones keep their relative order",
      reordered.order.firstIndex(of: .network)! < reordered.order.firstIndex(of: .disk)!)

check("moving up one place", standard.moving(.memory, by: -1).order.prefix(2) == [.memory, .cpu])
check("moving past the top stops at the top", standard.moving(.cpu, by: -1) == standard)
check("moving past the bottom stops at the bottom", standard.moving(.sensors, by: 3) == standard)
check("hiding then showing returns to the start",
      standard.setting(.cpu, shown: false).setting(.cpu, shown: true) == standard)
check("a hidden card is not visible", !standard.setting(.disk, shown: false).visible.contains(.disk))

let roundTrip = DashboardLayout.resolve(order: stored.storedOrder, hidden: stored.storedHidden)
check("a layout survives being stored", roundTrip == stored)
check("the stored hidden list is sorted, so it does not churn",
      standard.storedHidden == ["GPU", "Sensors"])

// MARK: - Storage

print("\nStorage")

func volume(total: UInt64, free: UInt64) -> StorageDetail {
    StorageDetail(volume: "Macintosh HD", total: total, free: free, readRate: nil, writeRate: nil,
                  readHistory: [], writeHistory: [])
}
let disk = volume(total: 195_383_263_232, free: 31_782_461_440)
check("used is capacity less available", disk.used == 195_383_263_232 - 31_782_461_440)
check("the ring's fraction is used over capacity",
      abs((disk.usedFraction ?? 0) - Double(disk.used) / Double(disk.total)) < 1e-12)
check("and rounds to the figure the card and popup show",
      Int(((disk.usedFraction ?? 0) * 100).rounded()) == 84)
check("a disk with no capacity draws no ring", volume(total: 0, free: 0).usedFraction == nil)
check("free larger than capacity is not a reading", volume(total: 100, free: 200).usedFraction == nil)
check("an empty disk is 0% used", volume(total: 100, free: 100).usedFraction == 0)
check("a full one is 100%", volume(total: 100, free: 0).usedFraction == 1)
check("used never goes below zero", volume(total: 100, free: 200).used == 0)

// MARK: - Grid

print("\nGrid")

let gap: CGFloat = 12
check("four cards in a 720pt window are two across",
      DashboardGrid.columns(for: 4, width: 484, spacing: gap) == 2)
check("four cards where three would fit are two, not three and one",
      DashboardGrid.columns(for: 4, width: 700, spacing: gap) == 2)
check("four cards where four fit are four", DashboardGrid.columns(for: 4, width: 930, spacing: gap) == 4)
check("never more than four", DashboardGrid.columns(for: 6, width: 4000, spacing: gap) == 3)
check("six where four fit are three across", DashboardGrid.columns(for: 6, width: 930, spacing: gap) == 3)
check("five, with no even split, take what fits", DashboardGrid.columns(for: 5, width: 930, spacing: gap) == 4)
check("too narrow for two is one", DashboardGrid.columns(for: 4, width: 300, spacing: gap) == 1)
check("one card is one column", DashboardGrid.columns(for: 1, width: 930, spacing: gap) == 1)
check("no width yet is one column", DashboardGrid.columns(for: 4, width: 0, spacing: gap) == 1)

// MARK: - Health

print("\nHealth")

check("no signals is normal", Health.level(Health.issues([])) == .normal)
check("a busy CPU in the warning band is not an issue",
      Health.issues([.cpu(recentLoad: 0.65, throttled: false)]).isEmpty)
check("sustained load at the critical band is elevated",
      Health.issues([.cpu(recentLoad: 0.85, throttled: false)]).first?.level == .elevated)
check("throttling needs attention whatever the load",
      Health.issues([.cpu(recentLoad: 0.1, throttled: true)]).first?.level == .attention)
check("a NaN load is not an issue", Health.issues([.cpu(recentLoad: .nan, throttled: false)]).isEmpty)

check("normal memory pressure is not an issue", Health.issues([.memory(pressure: 1)]).isEmpty)
check("warning pressure is elevated", Health.issues([.memory(pressure: 2)]).first?.level == .elevated)
check("critical pressure needs attention", Health.issues([.memory(pressure: 4)]).first?.level == .attention)

check("an 85% disk is not an issue",
      Health.issues([.disk(used: 0.85, free: 30_000_000_000, volume: "Macintosh HD")]).isEmpty)
let fullish = Health.issues([.disk(used: 0.91, free: 16_000_000_000, volume: "Macintosh HD")])
check("a 91% disk is elevated", fullish.first?.level == .elevated)
check("and names the volume", fullish.first?.title.contains("Macintosh HD") == true)
check("and opens the Disk page", fullish.first?.module == "Disk")
check("a 96% disk needs attention",
      Health.issues([.disk(used: 0.96, free: 7_000_000_000, volume: "Data")]).first?.level == .attention)

check("a link that is up is not an issue", Health.issues([.network(linkUp: true)]).isEmpty)
check("no link is elevated, not alarming", Health.issues([.network(linkUp: false)]).first?.level == .elevated)

let mixed = Health.issues([.network(linkUp: false), .memory(pressure: 4),
                           .disk(used: 0.92, free: 1, volume: "HD")])
check("worst first", mixed.first?.level == .attention)
check("ties keep the order their signals came in",
      mixed.map(\.module) == ["RAM", "Network", "Disk"])
check("the level is the worst issue's", Health.level(mixed) == .attention)

check("the summary of nothing is that everything is normal",
      Health.summary([], watching: 4) == "Everything looks normal")
// The view depends on this: when the summary IS the issue's title, the
// row beneath must not print the title again. It did, and the status area
// read "Memory pressure is raised" twice, two lines apart. If this ever
// stops returning the title, `IssueRow`'s `showsTitle` rule needs revisiting
// rather than silently hiding a heading that is no longer duplicated.
check("one issue is its own title", Health.summary(Array(mixed.prefix(1)), watching: 4) == mixed[0].title)
check("two issues are counted rather than named, so nothing is duplicated",
      Health.summary(Array(mixed.prefix(2)), watching: 4) == "2 things to look at")
check("several are counted", Health.summary(mixed, watching: 4) == "3 things to look at")
check("with nothing on, it says so rather than all-clear",
      Health.summary([], watching: 0) != "Everything looks normal")

check("the recent mean is of the last ten samples",
      Health.recentMean(Array(repeating: 0.0, count: 50) + Array(repeating: 1.0, count: 10)) == 1)
check("fewer than ten is the mean of what there is",
      abs((Health.recentMean([0.2, 0.4]) ?? 0) - 0.3) < 1e-9)
check("no history is no mean", Health.recentMean([]) == nil)

// MARK: - macOS names

print("\nmacOS release names")

check("26 is Tahoe", MacOSRelease.name(major: 26) == "Tahoe")
check("15 is Sequoia", MacOSRelease.name(major: 15) == "Sequoia")
check("14 is Sonoma", MacOSRelease.name(major: 14) == "Sonoma")
// The table used to end in `case 26...`, which named every later release
// Tahoe. This Mac runs 27.0, measured with sw_vers.
check("27 is not called Tahoe", MacOSRelease.name(major: 27) == nil)
check("an unknown release is its version alone",
      MacOSRelease.describe(major: 27, minor: 0, patch: 0) == "macOS 27.0")
check("a known one carries its name", MacOSRelease.describe(major: 26, minor: 1, patch: 0) == "macOS Tahoe 26.1")
check("a patch shows only when there is one",
      MacOSRelease.version(major: 15, minor: 6, patch: 1) == "15.6.1"
      && MacOSRelease.version(major: 15, minor: 6, patch: 0) == "15.6")

// MARK: - Serial

print("\nSerial number")

check("all but the last four are hidden", SerialMask.masked("C02XK1ABJGH5") == "••••••••JGH5")
check("the mask keeps the length", SerialMask.masked("C02XK1ABJGH5").count == 12)
check("four or fewer are hidden whole", SerialMask.masked("ABCD") == "••••")
check("empty stays empty", SerialMask.masked("") == "")

// MARK: - Uptime

print("\nUptime")

check("minutes alone", Uptime.describe(seconds: 12 * 60 + 5) == "12m")
check("hours and minutes", Uptime.describe(seconds: 4 * 3_600 + 12 * 60) == "4h 12m")
check("a zero hour inside a day still shows", Uptime.describe(seconds: 86_400 + 5 * 60) == "1d 0h 5m")
check("a nonsense interval is a dash", Uptime.describe(seconds: -5) == "—")

// MARK: - Battery

print("\nBattery")

// Exactly what `system_profiler SPPowerDataType -json -detailLevel mini`
// printed on this Mac (M2 Air), with the serial number taken out. System
// Settings showed the same three: 100%, 18 cycles, Normal.
let profiler = Data("""
{"SPPowerDataType":[{"_name":"spbattery_information",
 "sppower_battery_charge_info":{"sppower_battery_at_warn_level":"FALSE","sppower_battery_fully_charged":"FALSE",
   "sppower_battery_is_charging":"FALSE","sppower_battery_state_of_charge":70},
 "sppower_battery_health_info":{"sppower_battery_cycle_count":18,"sppower_battery_health":"Good",
   "sppower_battery_health_maximum_capacity":"100%"}},
 {"_name":"sppower_information"}]}
""".utf8)
let read = BatteryHealth.parse(profilerJSON: profiler)
check("maximum capacity is read as the system states it", read?.maximumCapacity == 100)
check("cycle count is read", read?.cycleCount == 18)
check("the condition is the system's word", read?.condition == "Good")
check("which System Settings calls Normal", BatteryHealth.describe(condition: "Good").title == "Normal"
      && BatteryHealth.describe(condition: "Good").tone == .good)
check("Check Battery is shown as Service recommended",
      BatteryHealth.describe(condition: "Check Battery").tone == .attention)
check("a permanent failure is the worst tone",
      BatteryHealth.describe(condition: "Permanent Battery Failure").tone == .failure)
check("a condition nobody has seen is shown as written, not guessed",
      BatteryHealth.describe(condition: "Calibrating").title == "Calibrating"
      && BatteryHealth.describe(condition: "Calibrating").tone == .unknown)

let desktop = Data(#"{"SPPowerDataType":[{"_name":"sppower_information"}]}"#.utf8)
check("a Mac with no battery reports no health", BatteryHealth.parse(profilerJSON: desktop) == nil)
check("output that is not JSON is no report", BatteryHealth.parse(profilerJSON: Data("oops".utf8)) == nil)
let odd = Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":-1,"sppower_battery_health":"","sppower_battery_health_maximum_capacity":"0%"}}]}"#.utf8)
let oddRead = BatteryHealth.parse(profilerJSON: odd)
check("a nonsense capacity is not a reading", oddRead?.maximumCapacity == nil)
check("nor a negative cycle count", oddRead?.cycleCount == nil)
check("nor an empty condition", oddRead?.condition == nil)

func source(_ extra: [String: Any]) -> [String: Any] {
    [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
     kIOPSCurrentCapacityKey: 70, kIOPSMaxCapacityKey: 100,
     kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue].merging(extra) { $1 }
}
check("the charge is current over maximum", BatteryHealth.charge(from: source([:]))?.percent == 70)
check("on battery is on battery", BatteryHealth.charge(from: source([:]))?.state == .onBattery)
check("charging is charging", BatteryHealth.charge(from: source([kIOPSIsChargingKey: true,
      kIOPSPowerSourceStateKey: kIOPSACPowerValue]))?.state == .charging)
check("plugged in and full is charged", BatteryHealth.charge(from: source([kIOPSIsChargedKey: true,
      kIOPSPowerSourceStateKey: kIOPSACPowerValue]))?.state == .charged)
check("plugged in and holding is said so", BatteryHealth.charge(from: source([
      kIOPSPowerSourceStateKey: kIOPSACPowerValue]))?.state == .onAdapter)
check("a UPS is not the Mac's battery", BatteryHealth.charge(from: source([kIOPSTypeKey: "UPS"])) == nil)
check("a battery that is not present is none", BatteryHealth.charge(from: source([kIOPSIsPresentKey: false])) == nil)
check("a zero maximum is not a reading", BatteryHealth.charge(from: source([kIOPSMaxCapacityKey: 0])) == nil)
check("charge never reads over 100%", BatteryHealth.charge(from: source([kIOPSCurrentCapacityKey: 120]))?.percent == 100)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
