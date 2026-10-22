//
//  sensors-test.swift
//
//  Exercises the sensor layer: the byte decoding, the family rule, and what
//  survives the plausibility filter.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Monitor/Temperature.swift Roost/Monitor/SMCKit.swift \
//            Roost/Monitor/SensorReadings.swift \
//            Tools/sensors-test.swift | swift -
//
//  A fake controller does most of the work here, and not for convenience:
//  the machine this was written on is a MacBook Air, which has no fans, so
//  no fan reading can be produced on it at all. The cases that matter -- a
//  fan at 2,400 rpm, a key reading back nonsense, a controller that answers
//  nothing -- are written down instead. The live checks assert only what must
//  hold on any Mac, and report themselves skipped where there is no
//  controller to ask: a CI runner is a virtual machine and has none.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// Counted and printed, never passed off as a pass.
///
/// The live checks need the machine's own controller. There is no `AppleSMC`
/// inside a virtual machine, which is what a CI runner is, and a check that
/// reports "ok" when it could not run is the kind of green that is worse than
/// a red one.
var skipped = 0
func skip(_ name: String, _ because: String) {
    print("  skip \(name) -- \(because)")
    skipped += 1
}

/// A controller that answers whatever the test says it does.
struct FakeSMC: SensorReadings.SMCSource {
    var values: [String: Double]
    func allKeys() -> [String] { values.keys.sorted() }
    func read(_ key: String) -> Double? { values[key] }
}

// MARK: - Decoding, through the client's own surface

print("SMCKit decoding")

live: do {
    // The decoder itself lives in SMCKit and is private to it, so this
    // checks it the way a caller can: ask the controller what a key is,
    // ask what it reads, and hold the pair to what the type promises.
    let smc = SMCKit.shared
    guard smc.isAvailable else {
        skip("the live checks", "no AppleSMC on this machine")
        break live
    }
    let keys = smc.allKeys()

    // The value and the bound, both in the name. A live check that fails once
    // and passes the next fifteen times is only diagnosable if the log says
    // what it saw -- and this one did exactly that. The bound goes in beside
    // it because "1762 keys" means nothing to somebody who does not know the
    // check wanted more than a hundred, and the person reading this log is on
    // a Mac none of us has.
    check("the key table is walked, not guessed at "
          + "(\(keys.count) keys, needs > 100)",
          keys.count > 100)
    // `#KEY` is the key *count*, not a reading, and it is in the table like
    // anything else. What matters is not that the client hides it but that
    // it never reaches the sensor list -- the family rule drops it, because
    // "#" is not one of the five letters.
    check("the key count is in the table, as it should be", keys.contains("#KEY"))
    check("but it is never offered as a sensor",
          !SensorReadings.all().contains { $0.id == "#KEY" })

    var decoded = 0
    for key in keys.prefix(400) {
        guard let type = smc.type(key), let value = smc.value(key) else { continue }
        decoded += 1
        if !value.isFinite {
            check("\(key) (\(type)) decoded to something that is not a number", false)
            break
        }
    }
    check("several hundred keys decode to finite numbers "
          + "(\(decoded) of 400, needs > 50)",
          decoded > 50)

    // A float key read twice in a row must not change by orders of
    // magnitude: that is the signature of a misaligned struct, which is
    // the failure this client already had once and fixed.
    if let first = smc.value("VP0R"), let second = smc.value("VP0R"), first > 0 {
        check(String(format: "a reading is stable across two calls "
                     + "(%.2f then %.2f, drift must stay under %.2f)",
                     first, second, max(1, first)),
              abs(first - second) < max(1, first))
    } else {
        skip("a reading is stable across two calls", "no charger attached")
    }
}

// MARK: - The family rule

print("\nSensorReadings.family")

check("T is a temperature", SensorReadings.family(of: "TB0T") == .temperature)
check("V is a voltage", SensorReadings.family(of: "VP0R") == .voltage)
check("I is a current", SensorReadings.family(of: "ID0R") == .current)
check("P is power", SensorReadings.family(of: "PSTR") == .power)
check("F is a fan", SensorReadings.family(of: "F0Ac") == .fan)
check("a key outside the five is not guessed at",
      SensorReadings.family(of: "#KEY") == nil)
check("nor is an empty key", SensorReadings.family(of: "") == nil)

// MARK: - What survives the filter

print("\nSensorReadings.smcSensors")

do {
    // The Mac this cannot be run on: one with fans.
    let withFans = FakeSMC(values: ["F0Ac": 2400, "F1Ac": 1800, "F0Mx": 6000,
                                    "PSTR": 18.5, "TB0T": 31])
    let sensors = SensorReadings.smcSensors(from: withFans)
    check("fans are read on a Mac that has them",
          sensors.filter({ $0.family == .fan }).count == 3)
    check("and are named", sensors.first { $0.id == "F0Ac" }?.name == "Fan 1")
    check("and formatted as whole revolutions",
          sensors.first { $0.id == "F0Ac" }?.formatted == "2400 rpm")
    check("power is formatted in watts",
          sensors.first { $0.id == "PSTR" }?.formatted == "18.50 W")
    check("temperature is formatted in degrees",
          sensors.first { $0.id == "TB0T" }?.formatted == "31°")
}

do {
    // Readings that cannot be true are a key being misread, not a machine
    // on fire.
    let wild = FakeSMC(values: ["TB0T": 9000, "VP0R": 500, "F0Ac": 90_000,
                                "PSTR": -40, "ID0R": .nan, "IB0R": .infinity])
    check("an impossible reading is left out entirely",
          SensorReadings.smcSensors(from: wild).isEmpty)
}

do {
    // A key that exists but is wired to nothing reads zero on this model.
    // An unnamed one is noise; a named one is a real answer.
    let quiet = FakeSMC(values: ["Tx99": 0, "PSTR": 0])
    let sensors = SensorReadings.smcSensors(from: quiet)
    check("an unnamed key reading zero is dropped",
          !sensors.contains { $0.id == "Tx99" })
    check("a named key reading zero is kept, because zero watts is an answer",
          sensors.contains { $0.id == "PSTR" })
}

do {
    let unknown = FakeSMC(values: ["Ts0P": 40.5, "Xyz1": 5])
    let sensors = SensorReadings.smcSensors(from: unknown)
    check("a key with no name keeps its key as its name",
          sensors.first { $0.id == "Ts0P" }?.name == "Ts0P")
    check("a key outside the five families is not reported at all",
          !sensors.contains { $0.id == "Xyz1" })
}

do {
    check("a controller that answers nothing yields nothing",
          SensorReadings.smcSensors(from: FakeSMC(values: [:])).isEmpty)
    check("and the whole list still builds without one",
          SensorReadings.all(includingHID: false, smc: nil).isEmpty)
}

// MARK: - Order

print("\nOrder")

do {
    let mixed = FakeSMC(values: ["VP0R": 12, "TB0T": 30, "F0Ac": 2000,
                                 "PSTR": 10, "ID0R": 1])
    let families = SensorReadings.all(includingHID: false, smc: mixed).map { $0.family }
    check("temperatures come first, then fans, then the electrical families",
          families == [.temperature, .fan, .power, .voltage, .current])
    check("the order is stable across two reads",
          SensorReadings.all(includingHID: false, smc: mixed).map({ $0.id })
            == SensorReadings.all(includingHID: false, smc: mixed).map({ $0.id }))
}

// MARK: - This Mac

print("\nOn this Mac")

onThisMac: do {
    // Same gate as the decoding block above, and it is here because leaving
    // it out is what made tests.yaml red on every run from the day it was
    // added. A CI runner is a virtual machine: no AppleSMC, no HID
    // temperature sensors, so `all()` returns nothing and "something
    // answered" fails -- not because the reader is broken but because there
    // is nothing on the other end of it.
    //
    // Gated on the controller rather than on the result. An empty list on a
    // Mac that *has* an SMC is a real failure and still fails.
    guard SMCKit.shared.isAvailable else {
        skip("the readings on this Mac", "no AppleSMC on this machine")
        break onThisMac
    }

    let live = SensorReadings.all()
    check("something answered", !live.isEmpty)
    check("every reading is a number", live.allSatisfy { $0.value.isFinite })
    check("every reading is plausible for its family",
          live.allSatisfy { $0.family.plausible.contains($0.value) })
    check("every sensor has an identity", live.allSatisfy { !$0.id.isEmpty })
    check("identities are unique", Set(live.map { $0.id }).count == live.count)
    check("every sensor formats without crashing",
          live.allSatisfy { !$0.formatted.isEmpty })

    let temperatures = live.filter { $0.family == .temperature }
    check("the HID sensors are in there",
          temperatures.contains { $0.id.hasPrefix("hid:") })

    // The strongest check available without a second instrument: the DC
    // input's power should be its voltage times its current. If the decoder
    // were wrong about any of the three, this would not hold.
    let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.value) })
    if let volts = byID["VD0R"], let amps = byID["ID0R"], let watts = byID["PDTR"],
       watts > 0.5 {
        check(String(format: "DC in power matches its own volts times amps "
                     + "(%.2f W vs %.2f W, gap must stay under %.2f)",
                     watts, volts * amps, max(1.0, watts * 0.15)),
              abs(watts - volts * amps) < max(1.0, watts * 0.15))
    } else {
        check("nothing is plugged in, so there is no product to check", true)
    }
}

// MARK: - The span a chart is drawn against

print("\nSensorSpan")

do {
    // A die between 45 and 47 is a flat line against an axis from zero, and
    // a flat line is what a temperature chart must not show while the
    // temperature is moving.
    let span = [45.0, 46.0, 47.0].range()
    check("the span follows the readings, not zero", span.low > 40 && span.high < 52)
    check("the lowest reading is near the floor", span.normalise(45) < 0.2)
    check("the highest is near the ceiling", span.normalise(47) > 0.8)
    check("the middle is in the middle", abs(span.normalise(46) - 0.5) < 0.01)
}

do {
    // A sensor that has not moved at all still has to draw as a line
    // through the middle rather than at the floor.
    let flat = [50.0, 50.0, 50.0].range()
    check("a series that has not moved draws through the middle",
          abs(flat.normalise(50) - 0.5) < 0.01)
    // An empty series has no span to speak of; what matters is that asking
    // it for a position still answers with one, inside the chart.
    let empty = [Double]().range()
    check("an empty series still answers, inside the chart",
          (0...1).contains(empty.normalise(10)) && empty.normalise(10).isFinite)
    check("a series of one does not either",
          [42.0].range().normalise(42).isFinite)
}

do {
    let span = [0.0, 100.0].range()
    check("a value past the top is held at the top", span.normalise(1000) == 1)
    check("a value below the bottom is held at the bottom", span.normalise(-1000) == 0)
    check("a value that is not a number does not reach the chart",
          span.normalise(.nan) == 0)
    check("nor an infinite one", span.normalise(.infinity) == 1 || span.normalise(.infinity) == 0)
    check("non-finite readings are left out of the span entirely",
          [1.0, .nan, 3.0].range().high < 10)
}

let note = skipped == 0 ? "" : " (\(skipped) skipped)"
print("\nOne sensor read again")

do {
    // The menu bar refreshes only the sensor it shows; the rest of the
    // table is read every half minute. Reading one must agree with reading
    // all, and must not invent a reading the full walk would have dropped.
    var values: [String: Double] = ["TC0P": 41, "PSTR": 12.5]
    let first = SensorReadings.smcSensors(from: FakeSMC(values: values))
    let cpu = first.first { $0.id == "TC0P" }!
    values["TC0P"] = 57
    let again = SensorReadings.reread(cpu, includingHID: false, smc: FakeSMC(values: values))
    check("a re-read sees the new value", again?.value == 57)
    check("and keeps the id, name and family", again?.id == cpu.id && again?.name == cpu.name
          && again?.family == cpu.family)
    values["TC0P"] = 900
    check("an implausible re-read is nil, as the full walk would drop it",
          SensorReadings.reread(cpu, includingHID: false, smc: FakeSMC(values: values)) == nil)
    values.removeValue(forKey: "TC0P")
    check("a sensor that stopped answering is nil",
          SensorReadings.reread(cpu, includingHID: false, smc: FakeSMC(values: values)) == nil)
}

print(failures == 0 ? "\nall passed\(note)" : "\n\(failures) failed\(note)")
exit(failures == 0 ? 0 : 1)
