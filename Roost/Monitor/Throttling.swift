import AppKit
import UserNotifications

/// Whether macOS is slowing the processor down to cool it.
///
/// Read from `ProcessInfo.thermalState`, the system's own verdict, rather
/// than guessed from a temperature: the point at which a fanless Air starts
/// holding back differs by model, by load and by how long it has been warm,
/// and macOS is the one making the decision. It is public, free to read, and
/// announces its changes, so watching it costs nothing between them.
///
/// Why it is worth a word on screen: a MacBook Air at 96 °C running
/// slower than it should looks, from the outside, exactly like a slow Mac.
/// The only difference is the reason, and the reason is what tells somebody
/// to close the app heating it rather than restart the machine.
enum Throttling {

    enum Level: Int, Comparable {
        /// Nothing held back.
        case none
        /// macOS calls it "fair": warm, starting to manage it, not yet
        /// costing much speed.
        case warm
        /// "Serious": performance is being reduced.
        case throttled
        /// "Critical": reduced hard, to protect the hardware.
        case severe

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal:  self = .none
            case .fair:     self = .warm
            case .serious:  self = .throttled
            case .critical: self = .severe
            @unknown default: self = .none
            }
        }

        /// The status line's word when this outranks the load's own.
        var verdict: String? {
            switch self {
            case .throttled: return localized("Throttling")
            case .severe:    return localized("Throttling hard")
            case .none, .warm: return nil
            }
        }
    }

    static var current: Level { Level(ProcessInfo.processInfo.thermalState) }

    /// The menu bar's severity for the CPU figure: the load's own, raised
    /// while the Mac is held back. A processor slowed to cool down is news
    /// at 20% load -- arguably more so, since the load is low and the Mac
    /// still feels slow.
    static func severity(load: MenuBarReading.Severity, _ level: Level) -> MenuBarReading.Severity {
        switch level {
        case .none, .warm: return load
        case .throttled:   return max(load, .warning)
        case .severe:      return .critical
        }
    }

    // MARK: The alert

    static var alertsEnabled: Bool {
        get { Preferences.shared.bool("Throttle_alert", default: true) }
        set { Preferences.shared.set("Throttle_alert", newValue) }
    }

    private static var observer: NSObjectProtocol?
    private static var last: Level = .none

    /// One notification as the Mac starts being held back, not one per
    /// change: it can step between serious and critical several times in a
    /// minute, and none of those steps is new information.
    static func startWatching() {
        guard observer == nil else { return }
        last = current
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            let now = current
            defer { last = now }
            guard alertsEnabled, now >= .throttled, last < .throttled else { return }
            notify()
        }
    }

    private static func notify() {
        let content = UNMutableNotificationContent()
        content.title = localized("Your Mac is slowing down to cool off")
        content.body = localized("macOS has reduced the processor's speed. Busy apps will feel slower until it cools.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "roost-throttling", content: content, trigger: nil)
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                centre.add(request)
            case .notDetermined:
                centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { centre.add(request) }
                }
            default:
                break
            }
        }
    }
}
