import Foundation
import UserNotifications

/// Decides when a watched reading deserves a notification.
///
/// Pure, and deliberately so: the rule is all hysteresis and counting, which
/// is exactly the kind of thing that looks right and then fires twice, or
/// never, or every second for an hour. Given a reading it says what to do
/// about it, and `Tools/threshold-test.swift` holds it to account without a
/// notification centre anywhere near it.
///
/// The rule is the one the module being replaced used, kept because it is a
/// good rule and because the thresholds people have set are tuned to it:
///
/// - Two samples in a row at or over the threshold fire, once. One sample is
///   a spike -- an app launching, a build starting -- and alerting on a spike
///   is how a threshold alert turns into noise somebody switches off.
/// - Nothing fires again until the reading has been back under. Without that,
///   a processor sitting at 80% against a 75% threshold would alert every
///   second for as long as it stayed there.
/// - Coming back under withdraws what was shown, so Notification Centre is
///   not left holding an alert about a machine that has been idle for an
///   hour.
struct ThresholdTracker: Equatable {

    /// Samples in a row before it fires.
    static let consecutive = 2

    enum Outcome: Equatable {
        /// Nothing to do.
        case quiet
        /// Show it.
        case fire
        /// Take down what was shown.
        case withdraw
    }

    private var streak = 0
    private var fired = false

    /// Whether an alert is showing for this reading.
    var isShowing: Bool { fired }

    /// `threshold` is in whatever the reading is measured in.
    ///
    /// `below` turns the rule the other way up, for the readings where low is
    /// the bad end: free memory, and nothing else so far.
    mutating func check(_ value: Double, over threshold: Double,
                        below: Bool = false) -> Outcome {
        // A reading that is not a number is neither under the threshold nor
        // over it. Ignored rather than read as zero, because zero would
        // withdraw a live alert on the strength of one bad sample.
        guard value.isFinite else { return .quiet }

        if below ? value > threshold : value < threshold {
            streak = 0
            guard fired else { return .quiet }
            fired = false
            return .withdraw
        }

        guard !fired else { return .quiet }
        streak += 1
        guard streak >= Self.consecutive else { return .quiet }
        streak = 0
        fired = true
        return .fire
    }

    /// Forget everything, as though nothing had been seen. For a watch being
    /// switched off: leaving `fired` set would mean that switching it back on
    /// stayed silent until the reading had dipped.
    mutating func reset() {
        streak = 0
        fired = false
    }
}

/// What a stored threshold number means.
enum ThresholdScale {
    /// 1...100, the common case.
    case percent
    /// Megabytes. Swap, so far.
    case megabytes
    /// The kernel's own memory pressure levels: 1 normal, 2 warning,
    /// 4 critical. Stored as the number, so one comparison covers all three.
    case pressureLevel

    var suffix: String {
        switch self {
        case .percent:       return "%"
        case .megabytes:     return " MB"
        case .pressureLevel: return ""
        }
    }
}

/// A reading a module can be asked to watch.
///
/// The settings live under the keys the modules being replaced wrote --
/// `<Module>_notifications_<key>_state` and `_value` -- so a Mac with
/// thresholds set keeps them without anything being migrated, and the
/// pre-switch form of each, a single key holding a fraction, is carried over
/// rather than ignored.
protocol ThresholdKind: Hashable, CaseIterable {
    /// The module's name, as it appears in every other preference key.
    var module: String { get }
    /// The stem the setting is stored under.
    var key: String { get }
    var title: String { get }
    /// What the stored number means.
    var scale: ThresholdScale { get }
    /// Fires when the reading falls *below* the threshold rather than rising
    /// above it. Free memory is the only kind that works that way.
    var below: Bool { get }
    /// False where the hardware cannot supply the reading.
    var isAvailable: Bool { get }
    /// What a fresh install watches at.
    var defaultValue: Int { get }
    /// The identifier the alert is posted under. Carried over from the module
    /// being replaced, so an alert it left showing is the one this withdraws
    /// rather than a second one beside it.
    var notificationID: String { get }
    /// Turns the reading into the line the alert shows.
    func describe(_ value: Double) -> String

    /// What the setting was called before it grew a switch.
    ///
    /// A requirement rather than only an extension: RAM's utilization was
    /// stored under a different name from the one it uses now, and a member
    /// that only exists in the extension is resolved where it is written, not
    /// where it is overridden -- so the override would never have run.
    var legacyKey: String { get }

    /// Brings a setting written by an older version up to date.
    ///
    /// A requirement rather than only an extension, so a module whose
    /// setting changed shape in some way of its own -- memory pressure was
    /// stored as a word, swap as a number and a separate unit -- can do that
    /// work as well as the shared part.
    func migrateIfNeeded()
}

extension ThresholdKind {
    var below: Bool { false }
    var isAvailable: Bool { true }
    var scale: ThresholdScale { .percent }
    var defaultValue: Int { 75 }
    var notificationID: String { "Roost_\(module)_\(key)" }

    var stateKey: String { "\(module)_notifications_\(key)_state" }
    var valueKey: String { "\(module)_notifications_\(key)_value" }
    var legacyKey: String { "\(module)_notifications_\(key)" }

    var isWatched: Bool {
        get {
            migrateIfNeeded()
            return Preferences.shared.bool(stateKey, default: false)
        }
        nonmutating set { Preferences.shared.set(stateKey, newValue) }
    }

    /// The number it fires at, in whatever `scale` says.
    var level: Int {
        get {
            migrateIfNeeded()
            return clamp(Preferences.shared.int(valueKey, default: defaultValue))
        }
        nonmutating set { Preferences.shared.set(valueKey, clamp(newValue)) }
    }

    /// The level in the units the reading is measured in.
    var threshold: Double {
        switch scale {
        case .percent:       return Double(level) / 100
        case .megabytes:     return Double(level) * 1_048_576
        case .pressureLevel: return Double(level)
        }
    }

    func clamp(_ value: Int) -> Int {
        switch scale {
        case .percent:       return min(max(value, range.lowerBound), range.upperBound)
        case .megabytes:     return min(max(value, range.lowerBound), range.upperBound)
        case .pressureLevel: return [1, 2, 4].contains(value) ? value : 2
        }
    }

    /// What the settings stepper may offer, and what `clamp` enforces.
    var range: ClosedRange<Int> {
        switch scale {
        case .percent:       return 1...100
        // 64 MB to 64 GB of swap. Below that is noise and above it the
        // machine has problems a notification will not help with.
        case .megabytes:     return 64...65_536
        case .pressureLevel: return 1...4
        }
    }

    /// How far one press of the stepper moves it.
    var step: Int {
        switch scale {
        case .megabytes: return 64
        default:         return 1
        }
    }

    func migrateIfNeeded() { migrateLegacyFraction() }

    /// The pre-switch form: one key holding a fraction, which meant
    /// "watched, at this level".
    ///
    /// Migrated on first read rather than ignored. Somebody who set a
    /// threshold years ago should not quietly lose it because the storage
    /// changed shape, and it costs one `object(forKey:)` on a key that is
    /// removed the moment it is found.
    func migrateLegacyFraction() {
        let prefs = Preferences.shared
        guard prefs.exists(legacyKey) else { return }
        if let text = UserDefaults.standard.string(forKey: legacyKey),
           let fraction = Double(text), fraction > 0 {
            prefs.set(stateKey, true)
            prefs.set(valueKey, clamp(Int((fraction * 100).rounded())))
        }
        prefs.set(legacyKey, nil)
    }
}

/// CPU's five.
///
/// The sixth the module it replaced offered, a third "super" cluster, is not
/// here: no shipping Mac reports a third performance level, and inventing a
/// figure for it would be worse than not offering the switch.
/// `docs/ARCHITECTURE.md` records it.
enum CPUThreshold: String, CaseIterable, ThresholdKind {
    case total = "totalLoad"
    case system = "systemLoad"
    case user = "userLoad"
    case efficiency = "eCoresLoad"
    case performance = "pCoresLoad"

    var module: String { "CPU" }
    var key: String { rawValue }

    var title: String {
        switch self {
        case .total:       return localized("Total load")
        case .system:      return localized("System load")
        case .user:        return localized("User load")
        case .efficiency:  return localized("Power-saving cores load")
        case .performance: return localized("Fast cores load")
        }
    }

    /// Only on a machine with clusters to report.
    var isAvailable: Bool {
        switch self {
        case .efficiency, .performance: return CPUReadings.clusters != nil
        default: return true
        }
    }

    var notificationID: String {
        switch self {
        case .total:       return "Roost_CPU_totalUsage"
        case .system:      return "Roost_CPU_systemUsage"
        case .user:        return "Roost_CPU_userUsage"
        case .efficiency:  return "Roost_CPU_eCoresUsage"
        case .performance: return "Roost_CPU_pCoresUsage"
        }
    }

    func describe(_ value: Double) -> String {
        "\(title): \(Int((value * 100).rounded()))%"
    }
}

/// A memory reading that can be watched.
///
/// The four the module it replaces offered, under the same keys. Two of them
/// are not percentages and one of them fires the other way up, which is why
/// `ThresholdKind` grew a scale and a direction.
enum RAMThreshold: String, CaseIterable, ThresholdKind {
    /// Memory used, as a share of physical.
    case total
    /// Memory free. Fires on the way *down*.
    case free
    /// The kernel's own pressure level.
    case pressure
    /// Swap in use.
    case swap

    var module: String { "RAM" }
    var key: String { rawValue }

    var title: String {
        switch self {
        case .total:    return localized("Memory used")
        case .free:     return localized("Memory free")
        case .pressure: return localized("Memory running short")
        case .swap:     return localized("Swap in use")
        }
    }

    var below: Bool { self == .free }

    var scale: ThresholdScale {
        switch self {
        case .total, .free: return .percent
        case .pressure:     return .pressureLevel
        case .swap:         return .megabytes
        }
    }

    var defaultValue: Int {
        switch self {
        case .total:    return 75
        case .free:     return 75
        case .pressure: return 2        // warning
        case .swap:     return 1024     // the 1 GB the old default meant
        }
    }

    /// Carried over so an alert the old module left showing is the one this
    /// withdraws rather than a second one beside it.
    var notificationID: String {
        switch self {
        case .total:    return "Roost_RAM_totalUsage"
        case .free:     return "Roost_RAM_free"
        case .pressure: return "Roost_RAM_pressure"
        case .swap:     return "Roost_RAM_swap"
        }
    }

    /// `total` was stored under `totalUsage` before it grew a switch; the
    /// other three kept their own names.
    var legacyKey: String {
        self == .total ? "RAM_notifications_totalUsage" : "RAM_notifications_\(rawValue)"
    }

    func describe(_ value: Double) -> String {
        switch self {
        case .total, .free:
            return "\(title): \(Int((value * 100).rounded()))%"
        case .pressure:
            let level = MemoryReadings.Pressure(rawValue: Int(value)) ?? .normal
            return "\(title): \(localized(level.label))"
        case .swap:
            return "\(title): \(Readings.bytes(UInt64(max(0, value))))"
        }
    }

    /// The shared migration, plus the two settings that were not numbers.
    ///
    /// Pressure was stored as a word and swap as a number with a unit beside
    /// it. Both are rewritten once, in place, rather than left to be read as
    /// an integer -- which for "critical" would have come out as zero and
    /// quietly become a warning-level alert.
    func migrateIfNeeded() {
        migrateLegacyFraction()

        let prefs = Preferences.shared
        switch self {
        case .pressure:
            guard let word = UserDefaults.standard.string(forKey: valueKey) else { return }
            let level: Int
            switch word {
            case "critical": level = 4
            case "warning":  level = 2
            case "normal":   level = 1
            default:         level = defaultValue
            }
            prefs.set(valueKey, level)
        case .swap:
            guard let unit = UserDefaults.standard.string(forKey: "RAM_notifications_swap_unit")
            else { return }
            let megabytes: Double
            switch unit {
            case "KB": megabytes = 1.0 / 1024
            case "MB": megabytes = 1
            case "GB": megabytes = 1024
            case "TB": megabytes = 1024 * 1024
            default:   megabytes = 1
            }
            let stored = Preferences.shared.int(valueKey, default: defaultValue)
            prefs.set(valueKey, clamp(Int((Double(stored) * megabytes).rounded())))
            prefs.set("RAM_notifications_swap_unit", nil)
        default:
            break
        }
    }
}

/// GPU has one reading worth watching, and the module it replaces watched the
/// same one under the same key.
enum GPUThreshold: String, CaseIterable, ThresholdKind {
    case usage

    var module: String { "GPU" }
    var key: String { rawValue }
    var title: String { localized("Utilization") }
    var notificationID: String { "Roost_GPU_usage" }

    func describe(_ value: Double) -> String {
        "\(title): \(Int((value * 100).rounded()))%"
    }
}

/// Storage has one reading worth watching, and the module it replaces
/// watched the same one.
enum DiskThreshold: String, CaseIterable, ThresholdKind {
    case utilization

    var module: String { "Disk" }
    var key: String { rawValue }
    var title: String { localized("Disk usage") }
    var notificationID: String { "Roost_Disk_usage" }

    /// 80, as it was -- a disk is worth warning about later than a processor.
    var defaultValue: Int { 80 }

    /// The pre-switch form of this setting was called `free`, not
    /// `utilization`, even though the number it held was the used share.
    var legacyKey: String { "Disk_notifications_free" }

    func describe(_ value: Double) -> String {
        "\(title): \(Int((value * 100).rounded()))%"
    }
}

/// Watches a module's readings against the thresholds that are switched on.
///
/// One of these per module, driven from the module's own sample, so a
/// threshold costs no reading of its own -- the mistake in what it replaces,
/// where the notifications pane was a view that also did the watching.
///
/// Generic over the module's set of readings, because the rule is the same
/// for all of them and the only thing that differs is which numbers go in.
final class ThresholdWatcher<Kind: ThresholdKind> {

    private let title: String
    private var trackers: [Kind: ThresholdTracker] = [:]
    private var watchedLast: Set<Kind> = []

    /// `title` heads every alert this watcher posts.
    init(title: String) {
        self.title = title
    }

    /// Called on every sample. `reading` supplies the current value of each
    /// watched kind, or nil where this Mac cannot report it.
    func check(_ reading: (Kind) -> Double?) {
        let watched = Set(Kind.allCases.filter { $0.isAvailable && $0.isWatched })

        // A watch switched off takes its alert down with it and forgets what
        // it saw, so switching it back on does not stay silent waiting for a
        // dip that already happened.
        for kind in watchedLast.subtracting(watched) {
            if trackers[kind]?.isShowing == true {
                ThresholdNotice.withdraw(kind.notificationID)
            }
            trackers[kind]?.reset()
        }
        watchedLast = watched

        for kind in Kind.allCases where watched.contains(kind) {
            guard let value = reading(kind) else { continue }

            var tracker = trackers[kind] ?? ThresholdTracker()
            let outcome = tracker.check(value, over: kind.threshold, below: kind.below)
            trackers[kind] = tracker

            switch outcome {
            case .quiet:
                break
            case .fire:
                ThresholdNotice.show(id: kind.notificationID,
                                     title: title,
                                     detail: kind.describe(value))
            case .withdraw:
                ThresholdNotice.withdraw(kind.notificationID)
            }
        }
    }

    /// At quit. An alert about a reading nothing is watching any more is one
    /// that can never be taken down.
    func withdrawAll() {
        for (kind, tracker) in trackers where tracker.isShowing {
            ThresholdNotice.withdraw(kind.notificationID)
        }
        trackers.removeAll()
        watchedLast.removeAll()
    }
}

/// Posts and withdraws a threshold alert.
///
/// Authorisation is asked for once, and only when macOS says nobody has been
/// asked yet. What this replaces called `requestAuthorization` on every
/// single notification, which is both pointless and the shape of the problem
/// that had Roost appearing to ask for permission over and over.
enum ThresholdNotice {

    private static var askedThisLaunch = false

    static func show(id: String, title: String, detail: String) {
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                post(id: id, title: title, detail: detail)
            case .notDetermined:
                guard !askedThisLaunch else { return }
                askedThisLaunch = true
                centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    post(id: id, title: title, detail: detail)
                }
            default:
                // Refused. Saying so once a second in the log would be worse
                // than saying nothing.
                break
            }
        }
    }

    static func withdraw(_ id: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func post(id: String, title: String, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = detail
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Roost: threshold alert: \(error.localizedDescription)") }
        }
    }
}
