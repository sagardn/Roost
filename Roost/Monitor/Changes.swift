import Foundation

/// Fires when a watched value changes, once it has stayed changed.
///
/// Not a threshold: there is no line to cross, only a before and an after.
/// The confirmation count is the whole reason this is not a plain `!=` --
/// a connectivity probe through a link that is already struggling fails
/// occasionally for reasons that are not the link going down, and a public IP
/// read through one comes back wrong now and then. The module this replaces
/// wanted two matching answers before believing the connection had changed
/// and three before believing the address had; both counts are kept.
///
/// The first value seen is never a change. Starting the app is not an event
/// worth a notification, and treating it as one would mean an alert every
/// launch for every watch that is switched on.
struct ChangeTracker<Value: Equatable>: Equatable {

    struct Change: Equatable {
        let from: Value
        let to: Value
    }

    /// How many times in a row the new answer has to agree with itself.
    let confirmations: Int

    private var known: Value?
    /// The answer being considered, and how many times in a row it has come
    /// back the same.
    private var candidate: Value?
    private var streak = 0

    init(confirmations: Int = 1) {
        self.confirmations = max(1, confirmations)
    }

    /// Whether anything has been seen yet.
    var hasBaseline: Bool { known != nil }

    mutating func check(_ value: Value) -> Change? {
        guard let previous = known else {
            known = value
            return nil
        }
        guard value != previous else {
            candidate = nil
            streak = 0
            return nil
        }

        // Counting agreement with the *candidate*, not merely disagreement
        // with the known value. The difference matters and is the bug this
        // inherited and does not have: a watch waiting for three samples
        // would otherwise accept three *different* wrong answers as proof of
        // a change to the last of them, which is the exact failure a
        // confirmation count exists to prevent.
        if value == candidate {
            streak += 1
        } else {
            candidate = value
            streak = 1
        }
        guard streak >= confirmations else { return nil }

        candidate = nil
        streak = 0
        known = value
        return Change(from: previous, to: value)
    }

    /// Forget the baseline, so the next value seen becomes the new one
    /// without being reported. For a watch being switched off and on again.
    mutating func reset() {
        known = nil
        candidate = nil
        streak = 0
    }
}
