import Foundation
import IOKit

/// The hardware sensors this Mac publishes.
///
/// Two sources, because neither covers the other:
///
/// - **The HID sensor service**, which `Temperature` already reads. Its
///   sensors carry their own names -- "PMU tdie1", "NAND CH0 temp" -- so
///   nothing has to be looked up to present them. 38 answer on an M2.
/// - **AppleSMC**, which adds the families HID has none of: voltage,
///   current and power. Reading it needs no privilege; only *writing* a key
///   does, which is why fan control is a separate question entirely.
///
/// The module this replaces carried a 587-line table mapping SMC keys to
/// human names. That table is not reproduced: it is somebody else's
/// transcription of undocumented firmware keys, and most of its entries
/// cannot be verified on any one machine. Roost names a sensor whatever the
/// system calls it, and from SMC exposes only the handful of keys whose
/// reading could be checked against something else -- see `knownKeys`.
enum SensorReadings {

    /// What kind of thing a sensor measures. Decides the unit, the
    /// formatting, and whether a reading is plausible.
    enum Family: String, CaseIterable {
        case temperature, voltage, current, power, fan

        /// The heading over a group. The raw value is storage, and was shown
        /// as-is: a lower-case "temperature" over the list, in every language.
        var title: String {
            switch self {
            case .temperature: return localized("Temperatures")
            case .voltage:     return localized("Voltages")
            case .current:     return localized("Currents")
            case .power:       return localized("Power")
            case .fan:         return localized("Fans")
            }
        }

        var unit: String {
            switch self {
            case .temperature: return "°C"
            case .voltage:     return "V"
            case .current:     return "A"
            case .power:       return "W"
            case .fan:         return "rpm"
            }
        }

        /// What a working sensor of this kind can read. Anything outside it
        /// is a key being misread, not a machine on fire.
        var plausible: ClosedRange<Double> {
            switch self {
            case .temperature: return -40...150
            case .voltage:     return -30...30
            case .current:     return -40...40
            case .power:       return 0...400
            case .fan:         return 0...12_000
            }
        }
    }

    struct Sensor: Equatable, Identifiable {
        /// The SMC key, or the HID sensor's name. Stable across launches,
        /// and the key every setting about this sensor is stored under.
        let id: String
        /// What to call it on screen.
        let name: String
        let family: Family
        let value: Double

        var formatted: String {
            switch family {
            case .temperature: return String(format: "%.0f°", value)
            case .voltage:     return String(format: "%.2f V", value)
            case .current:     return String(format: "%.2f A", value)
            case .power:       return String(format: "%.2f W", value)
            case .fan:         return "\(Int(value)) rpm"
            }
        }
    }

    // MARK: - Reading

    /// What the sensor layer needs of an SMC client.
    ///
    /// A protocol rather than the concrete client, for two reasons that both
    /// matter: the transport belongs to a different file than the naming and
    /// grouping, and a fake standing in for it is the only way to test a
    /// Mac with fans from a Mac without any.
    protocol SMCSource {
        /// Every key the controller publishes.
        func allKeys() -> [String]
        /// A key's value, already decoded, or nil if it is absent or of a
        /// type the client does not read.
        func read(_ key: String) -> Double?
    }

    /// Every sensor that answered, named and grouped.
    ///
    /// Temperatures first, then the electrical families, each alphabetical
    /// -- a stable order, so a list does not reshuffle between reads.
    static func all(includingHID hid: Bool = true, smc: SMCSource? = SMCKit.shared) -> [Sensor] {
        var found: [Sensor] = []
        if hid { found += hidSensors() }
        if let smc { found += smcSensors(from: smc) }

        return found.sorted { lhs, rhs in
            if lhs.family != rhs.family {
                return order(lhs.family) < order(rhs.family)
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// One sensor read again, by id, without walking the rest.
    ///
    /// For the menu bar, which shows a single reading: re-reading every
    /// sensor to refresh one was most of the Sensors module's cost. nil if
    /// the sensor no longer answers plausibly.
    static func reread(_ sensor: Sensor, includingHID hid: Bool = true,
                       smc: SMCSource? = SMCKit.shared) -> Sensor? {
        if sensor.id.hasPrefix("hid:") {
            return hid ? hidSensors().first { $0.id == sensor.id } : nil
        }
        guard let smc, let value = smc.read(sensor.id), value.isFinite,
              sensor.family.plausible.contains(value) else { return nil }
        return Sensor(id: sensor.id, name: sensor.name, family: sensor.family, value: value)
    }

    private static func order(_ family: Family) -> Int {
        switch family {
        case .temperature: return 0
        case .fan:         return 1
        case .power:       return 2
        case .voltage:     return 3
        case .current:     return 4
        }
    }

    /// The HID sensors, which name themselves.
    ///
    /// Duplicates are real: a Mac reports several "gas gauge battery"
    /// sensors. They are numbered rather than dropped, because they are
    /// genuinely different sensors and a list that silently loses four of
    /// them is a list that cannot be trusted.
    private static func hidSensors() -> [Sensor] {
        var counts: [String: Int] = [:]
        return Temperature.readAll().compactMap { reading in
            guard Family.temperature.plausible.contains(reading.celsius) else { return nil }
            let seen = (counts[reading.name] ?? 0) + 1
            counts[reading.name] = seen
            let name = seen == 1 ? reading.name : "\(reading.name) \(seen)"
            return Sensor(id: "hid:\(name)", name: name,
                          family: .temperature, value: reading.celsius)
        }
    }

    /// Every SMC key that answers with a plausible reading.
    ///
    /// Discovered rather than listed: the controller publishes its own key
    /// table, so asking it what it has finds the keys nobody thought to
    /// name. 1,763 answer on an M2 and a few hundred carry a reading.
    static func smcSensors(from smc: SMCSource) -> [Sensor] {
        smc.allKeys().compactMap { key in
            guard let family = family(of: key),
                  let value = smc.read(key),
                  value.isFinite,
                  family.plausible.contains(value) else { return nil }
            // A reading of exactly zero from a key nobody named is almost
            // always a key that exists but is not wired to anything on this
            // model. Named keys are kept at zero, because zero watts is a
            // real answer.
            guard value != 0 || names[key] != nil else { return nil }
            return Sensor(id: key, name: names[key] ?? key, family: family, value: value)
        }
    }

    /// What a key measures, from the letter it begins with.
    ///
    /// The one piece of SMC convention this relies on, and it is the piece
    /// that is actually consistent across twenty years of Macs: T for
    /// temperature, V volts, I amps, P watts, F fans. A key outside those
    /// five is not guessed at -- it is left out, because a reading in the
    /// wrong unit is worse than no reading.
    static func family(of key: String) -> Family? {
        switch key.first {
        case "T": return .temperature
        case "V": return .voltage
        case "I": return .current
        case "P": return .power
        case "F": return .fan
        default:  return nil
        }
    }

    /// Human names for the keys whose meaning could be confirmed.
    ///
    /// Deliberately short. Each was checked against a second source on a
    /// real Mac -- `PSTR` against the wattage `powermetrics` reports, the
    /// charger pair against `system_profiler SPPowerDataType`, `TB0T`
    /// against the battery temperature `ioreg` publishes. Everything else
    /// keeps its key as its name.
    ///
    /// The module this replaces carried 587 lines of these. That table is
    /// somebody's transcription of undocumented firmware keys and most of it
    /// cannot be verified on any one machine, so it is not reproduced: a
    /// sensor named wrongly is worse than one named `Ts0P`, because one is
    /// opaque and the other is a lie with a number beside it.
    ///
    /// The fan entries will report on a Mac that has fans. This one is a
    /// MacBook Air and has none, so they are **unverified on this
    /// hardware** -- see `docs/ARCHITECTURE.md`.
    static let names: [String: String] = [
        "PSTR": "System total power",
        "PDTR": "DC in power",
        "PPBR": "Battery power",
        "VP0R": "Charger voltage",
        "VD0R": "DC in voltage",
        "ID0R": "DC in current",
        "IB0R": "Battery current",
        "TB0T": "Battery",
        "F0Ac": "Fan 1",
        "F1Ac": "Fan 2",
        "F0Mx": "Fan 1 maximum",
        "F1Mx": "Fan 2 maximum"
    ]
}

/// The span a series covers, for charting readings that do not start at zero.
///
/// A die sitting between 45 °C and 47 °C is a flat line against an axis from
/// zero, and a flat line is exactly what a temperature chart must not show
/// when the temperature is moving.
struct SensorSpan {
    let low: Double
    let high: Double

    func normalise(_ value: Double) -> Double {
        guard high > low, value.isFinite else { return 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    func normalised(_ values: [Double]) -> [Double] { values.map(normalise) }
}

extension Array where Element == Double {
    /// The span of this series, padded so a perfectly flat one still draws
    /// as a line through the middle rather than at the floor.
    func range() -> SensorSpan {
        let finite = filter { $0.isFinite }
        guard let low = finite.min(), let high = finite.max() else {
            return SensorSpan(low: 0, high: 1)
        }
        guard high - low > 0.001 else {
            return SensorSpan(low: low - 1, high: high + 1)
        }
        let padding = (high - low) * 0.1
        return SensorSpan(low: low - padding, high: high + padding)
    }
}

/// `SMCKit` is the transport; this is the model on top of it.
///
/// The split is deliberate and was agreed with the session that wrote the
/// client: opening the connection, walking the key table and turning a type
/// code into a number belong together and belong somewhere else. Naming,
/// grouping and deciding what is plausible belong here.
///
/// Both sessions wrote a client before agreeing which to keep, which is how
/// the decoding came to be checked twice: two implementations written
/// separately from the same protocol agreed on `VP0R` to two decimal places
/// -- 13.36 against 13.38 -- and on `TB0T` to within a fifth of a degree.
/// That agreement is better evidence than either could produce alone.
extension SMCKit: SensorReadings.SMCSource {
    func read(_ key: String) -> Double? { value(key) }
}
