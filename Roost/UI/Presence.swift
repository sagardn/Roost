import AppKit
import IOKit.pwr_mgt

/// Whether now is a reasonable moment to put a window in front of someone.
///
/// Only the support window asks. It appears roughly once a month and asks for
/// nothing but attention, so it is the one thing in Roost that should lose to
/// anything the user is actually doing.
enum Presence {

    /// True while the login window or the lock screen is up.
    ///
    /// `CGSessionCopyCurrentDictionary` is the public window-server call for
    /// session state; the key is absent rather than false when unlocked, hence
    /// the default.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Seconds since the user last did anything at all.
    ///
    /// The minimum across the event types rather than one of them: asking only
    /// about `.keyDown` says "idle for an hour" about someone who has been
    /// reading and scrolling, and asking only about `.mouseMoved` says the
    /// same about someone typing.
    ///
    /// `.combinedSessionState` so it counts input to other applications too --
    /// Roost is in the menu bar and almost never has focus, so its own event
    /// stream is close to silent even when the Mac is in constant use.
    static var secondsSinceInput: TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .scrollWheel,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return kinds
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    /// Why the window should wait, or nil if it may show.
    ///
    /// One reason, as a sentence, because it goes straight into the log and
    /// "the support window is delayed: a presentation is running" is the whole
    /// of what anyone reading that log needs.
    static func busyReason() -> String? {
        if isScreenLocked { return "the screen is locked" }
        if isPresenting { return "something is holding the display awake" }
        return nil
    }

    /// Whether an application is holding the display awake.
    ///
    /// This is the presentation, the video call and the screen share: all three
    /// take a power assertion to stop the display sleeping, and all three are
    /// cases where a donation window would appear on a projector.
    ///
    /// There is no public API for Focus, which would be the other signal worth
    /// having. The ways to get at it are reading
    /// `~/Library/DoNotDisturb/DB/Assertions.json` or sniffing Control
    /// Centre's preferences, and neither is an interface Apple offers or keeps
    /// stable -- the file has moved between releases. So Roost does not claim
    /// to know. Between the lock check, the idle check and this one, the
    /// occasions that matter are already covered, and the cost of being wrong
    /// is that a window asking for a donation appears at a bad moment once.
    private static var isPresenting: Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
              let counts = assertions?.takeRetainedValue() as? [String: Int] else { return false }
        let holds = [kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                     kIOPMAssertionTypeNoDisplaySleep as String]
        return holds.contains { (counts[$0] ?? 0) > 0 }
    }
}
