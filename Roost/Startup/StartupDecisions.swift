import Foundation

/// The three startup questions that are arithmetic, not AppKit.
///
/// All of them used to be inline in `AppDelegate`'s extensions, where none
/// could be checked: each needs either a version transition that has already
/// happened, a date a month in the past, or an idle machine. They are pure
/// here and the glue that calls them is a few lines.
enum StartupDecisions {

    // MARK: - "Roost was updated"

    /// Whether to tell the user the app just updated itself.
    ///
    /// Only when the version actually moved *forward*. A downgrade -- someone
    /// reinstalling an older build to check whether a bug is new -- is a
    /// version change, and congratulating them on an update they did not
    /// perform is wrong in the one case where they are already annoyed.
    ///
    /// An unparseable version on either side means no notice: the comparison
    /// cannot be made, and a notice is not worth guessing at.
    static func announcesUpdate(from previous: String, to current: String,
                                silent: Bool) -> Bool {
        guard !silent, previous != current,
              let was = Version(previous), let now = Version(current)
        else { return false }
        return now > was
    }

    // MARK: - The support window

    /// A month, in days -- the interval between asking.
    static let supportIntervalDays = 31

    /// Whether enough time has passed to ask about supporting Roost again.
    ///
    /// A clock that has gone backwards -- a timezone change, a correction by
    /// NTP, a restored backup -- produces a negative difference, which must
    /// not count as "ages ago". It counts as "not yet", because the honest
    /// answer to "how long since I last asked" is "I cannot tell".
    static func shouldAskForSupport(lastAsked: Int, now: Int) -> Bool {
        let days = (now - lastAsked) / 86_400
        return days > supportIntervalDays
    }

    /// Why showing the support window right now would be rude, or nil to go
    /// ahead.
    ///
    /// The window is a donation prompt, so every one of these is about not
    /// interrupting: not over a locked screen, not at a machine nobody is
    /// sitting at, and not while something is being presented or recorded.
    ///
    /// The one exception is deliberate. A prompt that has been pending for
    /// more than a week, reached by the user actually clicking something, is
    /// allowed past the busy check -- otherwise somebody who screen-shares
    /// all day is never asked at all, and the prompt waits forever.
    static func supportDelayReason(interaction: Bool,
                                   pendingDays: Int,
                                   screenIsLocked: Bool,
                                   secondsSinceInput: TimeInterval,
                                   busyReason: String?) -> String? {
        if screenIsLocked { return "the screen is locked" }
        if !interaction, secondsSinceInput > 60 { return "no recent user activity" }
        if let busyReason, !(interaction && pendingDays > 7) { return busyReason }
        return nil
    }

    // MARK: - How often to check for updates

    /// How long between update checks, or nil where the interval is not a
    /// repeating schedule.
    ///
    /// `.atStart` and `.silent` both check once, now, and never again, so
    /// there is no interval to return for them -- nil means "do not schedule",
    /// not "schedule with a default", which is the mistake a zero would
    /// invite.
    static func updateCheckInterval(_ interval: UpdateInterval) -> TimeInterval? {
        switch interval {
        case .oncePerDay:   return 86_400
        case .oncePerWeek:  return 86_400 * 7
        case .oncePerMonth: return 86_400 * 30
        default:            return nil
        }
    }
}
