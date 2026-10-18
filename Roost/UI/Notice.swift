import AppKit
import UserNotifications

/// A Notification Centre alert from Roost itself, rather than from a reading.
///
/// Two of them exist: "Roost was updated to vX" and "a new version is
/// available", the second of which has to carry the download URL and be
/// clickable, which is why this takes `userInfo` and a delegate where
/// `ThresholdNotice` does not.
///
/// It deliberately does not share code with `ThresholdNotice`, which posts the
/// same four UserNotifications calls for CPU and memory alerts. That one is
/// compiled on its own by `Tools/threshold-test.swift` -- the suite feeds
/// `Thresholds.swift` to `swift -` and nothing else -- so a reference from
/// there to here would cost the test, and fifteen lines of UNMutableNotification
/// plumbing is a cheaper thing to have twice than a test is to lose.
enum Notice {

    /// Asked at most once per launch, and only when macOS says nobody has
    /// been asked yet. Before this, every notification called
    /// `requestAuthorization` first, which is what made Roost look like it
    /// kept asking for permission.
    private static var askedThisLaunch = false

    /// Returns the identifier, so the caller can withdraw it later -- the
    /// "updated to vX" alert takes itself down after ten seconds.
    @discardableResult
    static func post(title: String,
                     detail: String? = nil,
                     userInfo: [AnyHashable: Any] = [:],
                     delegate: UNUserNotificationCenterDelegate? = nil) -> String {
        let id = UUID().uuidString
        let centre = UNUserNotificationCenter.current()
        // Set before authorisation is settled: a notification tapped while the
        // app had no delegate goes nowhere, and the delegate is what turns the
        // update alert into an install.
        if let delegate { centre.delegate = delegate }

        centre.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                send(id: id, title: title, detail: detail, userInfo: userInfo)
            case .notDetermined:
                guard !askedThisLaunch else { return }
                askedThisLaunch = true
                centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    send(id: id, title: title, detail: detail, userInfo: userInfo)
                }
            default:
                break
            }
        }
        return id
    }

    static func withdraw(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func send(id: String,
                             title: String,
                             detail: String?,
                             userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let detail { content.subtitle = detail }
        content.userInfo = userInfo
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("notification: \(error.localizedDescription)") }
        }
    }
}
