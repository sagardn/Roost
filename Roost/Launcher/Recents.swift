import AppKit

/// Remembers when each app was last brought to the front, so the search list
/// can lead with what you actually use.
///
/// This listens to NSWorkspace's activation notification rather than only
/// recording Roost's own picks, so switching with Cmd-Tab, the Dock or a
/// click all count. It is a passive notification, not a polling watcher.
final class Recents {
    static let shared = Recents()

    private let key = "recentApps"
    private let limit = 200
    private var lastUsed: [String: Double] = [:]

    private init() {
        lastUsed = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self,
                           selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification,
                           object: nil)
        // seed with whatever is in front right now, otherwise it stays unranked
        // until the next switch
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            record(front)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,   // ignore ourselves
              isRealApp(app)
        else { return }
        WindowControl.invalidateState(bundleID)
        record(bundleID)
    }

    /// Filters out the system UI that borrows focus for a moment — the
    /// password prompt, the Accessibility permission dialog, notification
    /// banners. They are genuine frontmost activations, so without this they
    /// outrank the apps you were actually using.
    ///
    /// The test is where the bundle lives rather than a list of names:
    /// real apps sit in /Applications or /System/Applications, while these
    /// agents live under /System/Library.
    private func isRealApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        guard let path = app.bundleURL?.path else { return false }
        return !path.contains("/System/Library/")
    }

    private func record(_ bundleID: String) {
        lastUsed[bundleID] = Date().timeIntervalSince1970
        if lastUsed.count > limit {
            let keep = lastUsed.sorted { $0.value > $1.value }.prefix(limit)
            lastUsed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(lastUsed, forKey: key)
    }

    /// One app the cycle can land on.
    ///
    /// A protocol rather than NSRunningApplication directly so the ordering and
    /// stepping can be tested without launching anything -- see
    /// Tools/switcher-test.swift.
    protocol Candidate {
        var cycleID: String { get }
        /// True once the app has quit. A snapshot taken when the cycle began
        /// can contain apps that are no longer there.
        var isGone: Bool { get }
    }

    /// The most recently used running apps, newest first.
    ///
    /// Unlike the old version this *includes* the app you are currently in.
    /// Leaving it out meant the unmarked cycle could walk away from where you
    /// started and never come back to it, while the marked cycle -- which did
    /// include it, demoted -- came round properly. One key, two behaviours.
    /// `ordered(_:frontmost:)` puts it last, which is where Cmd-Tab puts it.
    func recentRunningApps(limit: Int) -> [NSRunningApplication] {
        let ranked = NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return id != Bundle.main.bundleIdentifier && isRealApp(app)
            }
        return Recents.ordered(ranked, frontmost: frontmostID, lastUsed: lastUsed)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Cycling

    /// The index-and-window half of the cycle, with no AppKit in it.
    ///
    /// Split out because this is where the bugs were, and "it feels wrong" is
    /// not something you can fix by staring at it. Tools/switcher-test.swift
    /// drives it with a fake clock and fake apps.
    struct Cycler<T: Candidate> {
        /// Snapshotted when a cycle begins and reused until it lapses.
        /// Without that, activating an app makes it the most recent one, which
        /// reshuffles the list underneath and turns a walk backwards through
        /// history into a flip between two apps.
        private(set) var list: [T] = []
        private(set) var index = 0
        private var lastStepAt = Date.distantPast

        /// How long after a press the next one still continues the same walk.
        let window: TimeInterval

        init(window: TimeInterval = 1.5) { self.window = window }

        /// One press. Returns the app to activate, or nil when there is none.
        mutating func step(at now: Date, rebuild: () -> [T]) -> T? {
            if now.timeIntervalSince(lastStepAt) > window || list.isEmpty {
                list = rebuild()
                index = 0
            } else {
                index += 1
            }
            lastStepAt = now

            guard !list.isEmpty else { return nil }

            // A snapshot goes stale: an app that quit mid-cycle is still in
            // the list, and activating a terminated app does nothing -- so one
            // press of ⌃Tab did nothing at all, and the next press skipped a
            // step as well. Walk past anything that has gone.
            for _ in 0..<list.count {
                let candidate = list[index % list.count]
                if !candidate.isGone { return candidate }
                index += 1
            }
            return nil
        }
    }

    private var cycler = Cycler<NSRunningApplication>()

    private var frontmostID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The cycle order: most recently used first, the app you are in last.
    ///
    /// Deterministic on purpose. The old sort was
    /// `rank(for:) > rank(for:)` with `rank` returning `lastUsed[id] ?? 0`, so
    /// every app Roost had not seen activate yet scored exactly 0 -- and
    /// Swift's sort is not stable, which left the order of those apps
    /// arbitrary and free to change from one cycle to the next. That is what
    /// made ⌃Tab feel unpredictable: mark four apps, use two of them, and the
    /// other two swapped places at random. Ties now break on the identifier,
    /// so the same set always walks in the same order.
    static func ordered<T: Candidate>(_ apps: [T],
                                      frontmost: String?,
                                      lastUsed: [String: Double]) -> [T] {
        apps.sorted { lhs, rhs in
            let lhsIsFront = lhs.cycleID == frontmost
            let rhsIsFront = rhs.cycleID == frontmost
            if lhsIsFront != rhsIsFront { return rhsIsFront }
            let lhsUsed = lastUsed[lhs.cycleID] ?? 0
            let rhsUsed = lastUsed[rhs.cycleID] ?? 0
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.cycleID < rhs.cycleID
        }
    }

    /// Step to the next app in the cycle, Cmd-Tab style.
    ///
    /// `among` restricts the cycle to a chosen set of bundle identifiers --
    /// the marked apps. Order still comes from recency, so within the set it
    /// behaves like Cmd-Tab: one tap lands on the app you came from.
    ///
    /// Passing nil or an empty set cycles the ten most recent apps, which is
    /// what happens until something is marked. Marking an app is the opt-in;
    /// there is no separate switch to forget about.
    @discardableResult
    func cycleToNext(among marked: Set<String>? = nil) -> NSRunningApplication? {
        let app = cycler.step(at: Date()) { [weak self] in
            guard let self else { return [] }
            var candidates: [NSRunningApplication] = []
            if let marked, !marked.isEmpty {
                candidates = self.running(in: marked)
            }
            // One marked app running is not a cycle: ⌃Tab would re-activate
            // the app you are already in and look broken. Fall back to recents
            // so the key always does something.
            if candidates.count < 2 {
                candidates = self.recentRunningApps(limit: 10)
            }
            return candidates
        }
        if let app { WindowControl.toggleActivateOnly(app) }
        return app
    }

    /// The marked apps that are actually running, in cycle order.
    ///
    /// Marked-but-not-running apps are left out on purpose: Ctrl+Tab is for
    /// switching, and a tap that launches something is a different gesture --
    /// that is what the per-app Ctrl+digit keys and the search panel are for.
    private func running(in marked: Set<String>) -> [NSRunningApplication] {
        let matching = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return marked.contains(id) && app.activationPolicy == .regular
        }
        return Recents.ordered(matching, frontmost: frontmostID, lastUsed: lastUsed)
    }

    /// Higher is more recent. nil means never seen.
    func time(for bundleID: String) -> Double? { lastUsed[bundleID] }

    /// Rank for sorting the search results, most recent first.
    ///
    /// The app you are currently in is pushed to the back, the way Cmd-Tab
    /// leads with the app you came *from* rather than the one you are already
    /// looking at.
    func rank(for bundleID: String) -> Double {
        if frontmostID == bundleID { return -1 }
        return lastUsed[bundleID] ?? 0
    }
}

extension NSRunningApplication: Recents.Candidate {
    var cycleID: String { bundleIdentifier ?? "" }
    var isGone: Bool { isTerminated }
}
