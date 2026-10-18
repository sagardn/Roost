import Foundation
import IOKit
import IOKit.ps

/// The battery: how worn it is, and what it is doing now.
///
/// Two sources, because the system gives the two halves separately.
///
/// **Health -- maximum capacity, cycle count, condition -- is Apple's own
/// report**, read from `system_profiler SPPowerDataType -json`: the figures
/// System Settings ▸ Battery and System Information show, as they show them.
/// No public API returns Apple's maximum-capacity figure. The battery
/// controller's registry has the capacities it is computed from, and two
/// ratios of them both came to 100% on this Mac (nominal 4713 and full-charge
/// 4586 mAh against a design 4563), so they could not be told apart -- which
/// is exactly why neither is used: a ratio that happened to match here would
/// be an estimate presented as the official reading everywhere else. The
/// report costs a tenth of a second (measured: 0.10 s real) and is asked for
/// at most every half hour, while the Dashboard is open.
///
/// **Charge and charging state are `IOPowerSources`**, which is cheap and
/// current.
///
/// Neither is estimated. Where a figure is not reported, it is nil, and the
/// card says so.
enum BatteryHealth {

    // MARK: - Health

    struct Report: Equatable {
        /// Percent of design capacity, as the system states it.
        var maximumCapacity: Int?
        var cycleCount: Int?
        /// The condition, in the system's own word: "Good", "Check Battery",
        /// "Service Recommended", "Permanent Battery Failure"...
        var condition: String?
    }

    /// Reads `system_profiler`'s JSON. Pure, so it can be fed what the tool
    /// prints and checked.
    static func parse(profilerJSON data: Data) -> Report? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let cycles = (health["sppower_battery_cycle_count"] as? Int)
                ?? (health["sppower_battery_cycle_count"] as? String).flatMap { Int($0) }
            return Report(maximumCapacity: percent(health["sppower_battery_health_maximum_capacity"]),
                          cycleCount: cycles.flatMap { $0 >= 0 ? $0 : nil },
                          condition: (health["sppower_battery_health"] as? String)
                            .flatMap { $0.isEmpty ? nil : $0 })
        }
        return nil
    }

    /// "100%" or 100 to 100; anything that is not a sane percentage to nil.
    private static func percent(_ value: Any?) -> Int? {
        let number: Int?
        if let int = value as? Int {
            number = int
        } else if let text = value as? String {
            number = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        } else {
            number = nil
        }
        guard let number, (1...150).contains(number) else { return nil }
        return number
    }

    /// The tool, run off the main thread. nil when it fails or reports no
    /// battery -- a desktop Mac, or a tool that has changed its output.
    static func readReport(_ done: @escaping (Report?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPPowerDataType", "-json", "-detailLevel", "mini"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var report: Report?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { report = parse(profilerJSON: data) }
            } catch {
                report = nil
            }
            // The cycle count is also the controller's own register, so it
            // is read from there if the tool did not give it -- the same
            // number, not an estimate of one.
            if report?.cycleCount == nil, let cycles = registryCycleCount() {
                report = report ?? Report()
                report?.cycleCount = cycles
            }
            DispatchQueue.main.async { done(report) }
        }
    }

    private static func registryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        return value.flatMap { $0 >= 0 ? $0 : nil }
    }

    // MARK: - Condition

    enum Tone: Equatable { case good, attention, failure, unknown }

    /// What a condition is called, and how worried to be.
    ///
    /// The JSON says "Good" where System Settings says "Normal", and "Check
    /// Battery" -- the `IOPSKeys.h` value -- where it says "Service
    /// Recommended". Those two are translated to the words people see in
    /// System Settings. Anything else is shown as the system wrote it rather
    /// than guessed at.
    static func describe(condition: String) -> (title: String, tone: Tone) {
        switch condition.lowercased() {
        case "good", "normal":
            return (localized("Normal"), .good)
        case "check battery", "service recommended", "fair":
            return (localized("Service recommended"), .attention)
        case "permanent battery failure", "poor":
            return (localized("Service the battery"), .failure)
        default:
            return (condition, .unknown)
        }
    }

    // MARK: - Charge

    enum PowerState: Equatable {
        case charging, charged, onAdapter, onBattery

        var title: String {
            switch self {
            case .charging:  return localized("Charging")
            case .charged:   return localized("Charged")
            case .onAdapter: return localized("On power adapter, not charging")
            case .onBattery: return localized("On battery")
            }
        }
    }

    struct Charge: Equatable {
        /// 0...100.
        let percent: Int
        let state: PowerState
    }

    /// The internal battery's entry, from a power-source description. Pure,
    /// for the tests; nil for anything that is not an internal battery that
    /// is present and reports a sane charge.
    static func charge(from description: [String: Any]) -> Charge? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool ?? false,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0, current >= 0
        else { return nil }
        let percent = min(100, Int((Double(current) / Double(maximum) * 100).rounded()))
        let onAdapter = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let state: PowerState
        if description[kIOPSIsChargingKey] as? Bool == true {
            state = .charging
        } else if description[kIOPSIsChargedKey] as? Bool == true {
            state = .charged
        } else {
            state = onAdapter ? .onAdapter : .onBattery
        }
        return Charge(percent: percent, state: state)
    }

    /// The internal battery right now, or nil for a Mac without one.
    static func currentCharge() -> Charge? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let charge = charge(from: description) else { continue }
            return charge
        }
        return nil
    }
}
