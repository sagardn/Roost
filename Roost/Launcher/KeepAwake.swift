import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and its display from sleeping while it is on.
///
/// A power assertion, the mechanism `caffeinate` and every keep-awake app
/// use: public, needs no permission, and macOS lists it under the process
/// in `pmset -g assertions`, so it can always be seen who is holding the Mac
/// awake. The display assertion is the one taken, because "keep it awake"
/// is said by somebody watching something -- a long build, a download, a
/// presentation -- and a dark screen is the sleep they meant. It also stops
/// the idle sleep of the system behind it.
///
/// Not remembered across launches, deliberately. A Mac that never sleeps
/// because of a choice made last week, with nothing on screen saying so, is
/// the failure this is most likely to cause; macOS drops the assertion when
/// the process ends, and Roost starts each launch letting the Mac sleep.
final class KeepAwake {

    static let shared = KeepAwake()

    private var assertion: IOPMAssertionID = 0
    private(set) var isOn = false
    /// When a timed keep-awake lets the Mac sleep again; nil while it runs
    /// until turned off.
    private(set) var endsAt: Date?
    private var expiry: DispatchWorkItem?

    private init() {}

    /// Turns it on or off, and says whether it is now on. Fails only if
    /// macOS refuses the assertion, in which case it stays off.
    @discardableResult
    func toggle() -> Bool {
        isOn ? turnOff() : turnOn()
        return isOn
    }

    /// On, for `duration` seconds or until turned off. Called while already
    /// on, it changes how long for: "awake 2h" after "awake 1h" means two
    /// hours from now, not one more.
    ///
    /// The deadline is wall-clock. A `Timer` counts time the Mac is awake,
    /// so an hour's keep-awake with the lid shut for thirty minutes of it
    /// would have run half an hour long; somebody who said "for an hour" at
    /// two o'clock means until three.
    func turnOn(for duration: TimeInterval? = nil) {
        expiry?.cancel()
        expiry = nil
        endsAt = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.turnOff() }
            expiry = work
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + duration, execute: work)
        }
        guard !isOn else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Roost: Keep Mac Awake" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            Log.error("keep awake: IOPMAssertionCreateWithName returned \(result)")
            expiry?.cancel()
            expiry = nil
            endsAt = nil
            return
        }
        assertion = id
        isOn = true
    }

    /// "1 hour", "45 minutes", "1 hour, 30 minutes", in the Mac's language.
    static func describe(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        // Seconds when the time has some: "timer 30s" read "0 minutes",
        // and 90 seconds read "1 minute".
        let whole = duration.truncatingRemainder(dividingBy: 60) == 0
        formatter.allowedUnits = whole ? [.hour, .minute] : [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: duration) ?? "\(Int(duration / 60)) min"
    }

    /// A clock time, "14:30" or "2:30 PM" as the Mac is set to show them.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func turnOff() {
        expiry?.cancel()
        expiry = nil
        endsAt = nil
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isOn = false
    }
}
