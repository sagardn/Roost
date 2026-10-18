//
//  startup-test.swift
//
//  Exercises the three startup decisions: whether the app just updated,
//  whether to ask about supporting it, and how often to check for a release.
//
//  Run:  cat Roost/Settings/UpdateInterval.swift Roost/Update/Version.swift \
//            Roost/Startup/StartupDecisions.swift \
//            Tools/startup-test.swift | swift -
//
//  None of these could be checked where they used to live. The first needs a
//  version transition that has already happened, the second a date a month in
//  the past, the third an idle machine -- so all three shipped on the strength
//  of somebody reading them and agreeing. They were right; that is the point
//  of writing the cases down rather than the reason for it. A downgrade not
//  announcing itself as an update, and a clock that has gone backwards not
//  counting as "ages since we last asked", are both now pinned instead of
//  being properties the next edit can quietly remove.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: - "Roost was updated"

print("StartupDecisions.announcesUpdate")

func announces(_ from: String, _ to: String, silent: Bool = false) -> Bool {
    StartupDecisions.announcesUpdate(from: from, to: to, silent: silent)
}

check("a new version announces itself", announces("1.1.0", "1.1.1"))
check("across a minor", announces("1.1.9", "1.2.0"))
check("across a major", announces("1.9.9", "2.0.0"))

check("the same version says nothing", !announces("1.1.1", "1.1.1"))

// Reinstalling an older build to find out whether a bug is new is a version
// change, and being congratulated on an update you did not perform is wrong
// in the one case where you are already annoyed. The original got this right
// via a `movedForward` flag; this is the case that stops it being lost.
check("a downgrade does not announce an update", !announces("1.2.0", "1.1.0"))
check("nor a downgrade across a major", !announces("2.0.0", "1.9.9"))

check("the silent interval announces nothing", !announces("1.1.0", "1.1.1", silent: true))

// A version that cannot be parsed cannot be compared, and a notice is not
// worth guessing at.
check("an unparseable previous version says nothing", !announces("", "1.1.1"))
check("an unparseable current version says nothing", !announces("1.1.0", "unknown"))
check("neither parseable, nothing", !announces("x", "y"))

// MARK: - Asking about support

print("\nStartupDecisions.shouldAskForSupport")

let day = 86_400
let now = 1_760_000_000

check("the day it was last asked, no",
      !StartupDecisions.shouldAskForSupport(lastAsked: now, now: now))
check("a week later, no",
      !StartupDecisions.shouldAskForSupport(lastAsked: now - 7 * day, now: now))
check("exactly the interval, no -- it is strictly greater",
      !StartupDecisions.shouldAskForSupport(lastAsked: now - 31 * day, now: now))
check("a day past the interval, yes",
      StartupDecisions.shouldAskForSupport(lastAsked: now - 32 * day, now: now))
check("a year later, yes",
      StartupDecisions.shouldAskForSupport(lastAsked: now - 365 * day, now: now))

// A timezone change, an NTP correction or a restored backup can put the
// stored timestamp in the future; the difference goes negative, and a
// negative number of days is not "ages ago". The original got this right by
// accident of comparison -- it stopped when the difference was <= 31, and a
// negative difference is -- which means the next person to rewrite the
// comparison as `abs(days) > 31` would break it with no test to say so.
check("a timestamp in the future is not ages ago",
      !StartupDecisions.shouldAskForSupport(lastAsked: now + 400 * day, now: now))
check("nor one a second in the future",
      !StartupDecisions.shouldAskForSupport(lastAsked: now + 1, now: now))

// MARK: - Not interrupting

print("\nStartupDecisions.supportDelayReason")

func reason(interaction: Bool = false, pendingDays: Int = 0,
            locked: Bool = false, idle: TimeInterval = 0,
            busy: String? = nil) -> String? {
    StartupDecisions.supportDelayReason(interaction: interaction,
                                        pendingDays: pendingDays,
                                        screenIsLocked: locked,
                                        secondsSinceInput: idle,
                                        busyReason: busy)
}

check("an idle, unlocked, unbusy machine with recent input goes ahead",
      reason() == nil)
check("a locked screen waits", reason(locked: true) == "the screen is locked")
check("a locked screen wins even on interaction",
      reason(interaction: true, locked: true) == "the screen is locked")
check("nobody at the machine waits",
      reason(idle: 61) == "no recent user activity")
check("a minute of idle is still recent enough", reason(idle: 60) == nil)
check("but a click overrides idleness -- they are right there",
      reason(interaction: true, idle: 9999) == nil)
check("something being presented waits",
      reason(busy: "screen is being shared") == "screen is being shared")

// The deliberate exception: somebody who screen-shares all day would never
// be asked at all, so a prompt pending more than a week and reached by an
// actual click is allowed past the busy check.
check("a click on a week-old prompt goes ahead anyway",
      reason(interaction: true, pendingDays: 8, busy: "screen is being shared") == nil)
check("but not a fresh one", reason(interaction: true, pendingDays: 7,
                                    busy: "screen is being shared") != nil)
check("and not without the click",
      reason(interaction: false, pendingDays: 99, busy: "screen is being shared") != nil)
check("a locked screen still wins over the exception",
      reason(interaction: true, pendingDays: 99, locked: true,
             busy: "screen is being shared") == "the screen is locked")

// MARK: - How often to look for a release

print("\nStartupDecisions.updateCheckInterval")

check("once per day", StartupDecisions.updateCheckInterval(.oncePerDay) == 86_400)
check("once per week", StartupDecisions.updateCheckInterval(.oncePerWeek) == 86_400 * 7)
check("once per month", StartupDecisions.updateCheckInterval(.oncePerMonth) == 86_400 * 30)

// nil means "do not schedule", and must not be mistaken for zero. A zero
// interval on an NSBackgroundActivityScheduler is a scheduler that fires as
// often as the system will let it.
check("at start is not a schedule", StartupDecisions.updateCheckInterval(.atStart) == nil)
check("nor is silent", StartupDecisions.updateCheckInterval(.silent) == nil)
check("nor is never", StartupDecisions.updateCheckInterval(.never) == nil)

for interval in UpdateInterval.allCases {
    if let seconds = StartupDecisions.updateCheckInterval(interval) {
        check("\(interval.rawValue) is a positive interval", seconds > 0)
    }
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
