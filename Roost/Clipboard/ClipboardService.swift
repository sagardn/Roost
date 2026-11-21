import AppKit
import Combine

/// The one clipboard monitor, and the history it keeps.
///
/// Everything that shows the history -- the menu bar popup, the combined
/// popup's tile, the history window, the settings page -- observes this one
/// object. None of them watches the clipboard itself.
///
/// The watching is a change count. `NSPasteboard` posts no notification
/// when another app writes to it; what it offers is `changeCount`, an
/// integer that moves on every write, and reading it reads no content. So
/// the timer below reads one integer every three quarters of a second while
/// monitoring is on, and the clipboard's contents only when that integer
/// has moved -- and not even then when the move was Roost's own restore.
/// With monitoring off there is no timer at all.
final class ClipboardService: ObservableObject {

    static let shared = ClipboardService(
        pasteboard: NSPasteboard.general,
        store: ClipboardStore(directory: ClipboardStore.defaultDirectory,
                              persistent: ClipboardSettings.persistent),
        options: { ClipboardSettings.snapshot },
        frontmost: {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.localizedName)
        })

    /// Where the service stands, for every view that shows it.
    enum Status: Equatable {
        case off
        case on
        /// macOS is set to refuse Roost's reads of the clipboard -- System
        /// Settings ▸ Privacy & Security ▸ Paste from Other Apps.
        case blocked
    }

    @Published private(set) var history = ClipboardHistory()
    @Published private(set) var status: Status = .off
    @Published private(set) var isLoaded = false
    /// A storage problem worth telling somebody about: the index could not
    /// be read, or a save failed. Never contains clipboard content.
    @Published private(set) var problem: String?
    /// How many copies were left out since launch, by reason. Counted, never
    /// described: the reason is enough, and the content is the thing not to
    /// keep.
    @Published private(set) var skipped: [ClipboardCapture.Skip: Int] = [:]

    private let pasteboard: ClipboardPasteboard
    private let store: ClipboardStore
    private let options: () -> ClipboardOptions
    private let frontmost: () -> (id: String?, name: String?)

    /// Disk and image work. One serial queue, so two saves never race and
    /// nothing slow happens on the main thread.
    var background: (@escaping () -> Void) -> Void = { work in ClipboardService.queue.async(execute: work) }
    var foreground: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }
    /// Whether macOS will hand Roost the clipboard at all. Overridable for
    /// a test, which has no System Settings to consult.
    var accessDenied: () -> Bool = {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysDeny }
        return false
    }

    private static let queue = DispatchQueue(label: "com.sagar.roost.clipboard", qos: .utility)

    private var timer: Timer?
    private var lastSeen: Int
    /// The change count Roost's own last restore produced.
    private var ownWrite: Int?
    private var settingsObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// Every app that came to the front since the last look at the
    /// clipboard. The check runs up to a second after a copy, and by then the
    /// app it came from may be behind another: copy a password in an excluded
    /// app, ⌘-Tab away at once, and the frontmost app at the check was the
    /// new one -- the password was kept, and filed under the wrong app.
    private var activatedSinceCheck: Set<String> = []
    /// Retention is otherwise enforced only when something is added, so with
    /// no new copies a one-day entry outlived its day by as long as nobody
    /// copied anything.
    private var retentionTimer: Timer?
    private var started = false

    init(pasteboard: ClipboardPasteboard, store: ClipboardStore,
         options: @escaping () -> ClipboardOptions,
         frontmost: @escaping () -> (id: String?, name: String?)) {
        self.pasteboard = pasteboard
        self.store = store
        self.options = options
        self.frontmost = frontmost
        // Whatever is on the clipboard at launch was copied before Roost was
        // watching; taking it now would be capturing something nobody copied
        // with history on.
        self.lastSeen = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    /// Once, at launch. Loads the history off the main thread and starts
    /// watching if monitoring is on.
    func start() {
        guard !started else { return }
        started = true
        background { [self] in
            let entries = store.open()
            let trouble = store.problem
            foreground { [self] in
                history = ClipboardHistory(entries: entries)
                problem = trouble
                isLoaded = true
                // A quit that never reached `stop()` -- a crash, a forced
                // quit -- left the unpinned entries the setting promised to
                // clear. Cleared now, which is what that quit would have done.
                if ClipboardSettings.clearUnpinnedOnQuit { clear(keepingPinned: true) }
                apply()
                let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.enforce() }
                timer.tolerance = 300
                RunLoop.main.add(timer, forMode: .common)
                retentionTimer = timer
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.activatedSinceCheck.insert(id) }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard ClipboardSettings.isClipboardKey(note.object as? String) else { return }
            self?.apply()
        }
    }

    /// At quit. Synchronous: the process is about to end, and a save handed
    /// to a queue now would never run.
    func stop() {
        stopWatching()
        retentionTimer?.invalidate()
        retentionTimer = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        // Nothing to save until the history on disk has been read. Before
        // that, `history` is empty -- and saving it wrote an empty index over
        // the real one, after which the next launch deleted every image and
        // rich-text payload as an orphan. A quit during the first-run window
        // after a Reset, or in the moment after launch while the load is
        // still on its queue, did exactly that. Left alone, the file on disk
        // is the history, unchanged.
        guard isLoaded else { return }
        let removed = ClipboardSettings.clearUnpinnedOnQuit ? history.clear(keepingPinned: true) : []
        let entries = history.entries
        // On the store's own queue, which is the only place the store may be
        // used: run here on main, it raced a save that a copy just before
        // quitting had queued. That save, holding the older list, could land
        // after this one -- cleared entries came back next launch, pointing
        // at payloads already deleted -- or recreate a session-only folder
        // after `close()` had wiped it. `sync` cannot deadlock: this is main,
        // and the queue only ever reaches main with `async`.
        Self.queue.sync { [store] in
            if !removed.isEmpty { store.delete(removed) }
            try? store.save(entries)
            store.close()
        }
    }

    /// Brings everything in line with the settings: the timer on or off,
    /// the store's persistence, the limits.
    func apply() {
        // Not before the history on disk is read. A settings change in that
        // moment -- or any change at all, since a change with no key is
        // taken as possibly the clipboard's -- started the watching timer,
        // and the first copy then saved a one-entry history over the real
        // one. The load calls this itself once it is done.
        guard isLoaded else { return }
        let current = options()
        store.persistent = current.persistent
        if current.monitoring { startWatching() } else { stopWatching() }
        status = !current.monitoring ? .off : accessDenied() ? .blocked : .on
        enforce()
    }

    private func startWatching() {
        guard timer == nil else { return }
        // Not what is on the clipboard now: that was copied while history
        // was off, and turning it on is not copying it.
        lastSeen = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    var isWatching: Bool { timer != nil }

    // MARK: - Watching

    /// One look at the change count. Internal so a test can drive it
    /// without a timer.
    func check() {
        let changed = pasteboard.changeCount
        let recentlyFront = activatedSinceCheck
        activatedSinceCheck = []
        guard changed != lastSeen else { return }
        lastSeen = changed
        // Roost's own restore. The marker type catches it too, but this
        // costs nothing and needs no read at all.
        if changed == ownWrite { return }

        let current = options()
        guard current.monitoring else { return }
        if accessDenied() {
            status = .blocked
            return
        }
        let source = frontmost()
        // The app in front now, or any that was in front since the last
        // look: one of them made the copy, and if any is excluded the copy
        // is not kept. Erring this way loses an ordinary copy at worst;
        // the other way kept a password.
        let candidates = recentlyFront.union([source.id].compactMap { $0 })
        if !candidates.isDisjoint(with: current.excludedApps) {
            count(.excludedApp)
            return
        }

        switch ClipboardCapture.read(pasteboard, options: current.capture) {
        case .failure(let reason):
            if reason != .ownRestore && reason != .empty { count(reason) }
        case .success(let capture):
            status = .on
            add(capture, source: source)
        }
    }

    private func count(_ reason: ClipboardCapture.Skip) {
        skipped[reason, default: 0] += 1
    }

    private func add(_ capture: ClipboardCapture, source: (id: String?, name: String?)) {
        let date = Date()
        // Seen before: move it up, and write nothing -- the files it needs
        // are already on disk.
        if history.entries.contains(where: { $0.fingerprint == capture.fingerprint }) {
            history.add(ClipboardEntry(id: UUID(), kind: capture.kind, date: date, text: nil, fileURLs: nil,
                                       payloads: [], pixelWidth: nil, pixelHeight: nil, thumbnail: nil,
                                       isPinned: false, sourceBundleID: source.id, sourceName: source.name,
                                       types: capture.types, byteSize: 0, fingerprint: capture.fingerprint))
            save()
            return
        }
        background { [self] in
            do {
                let entry = try store.makeEntry(from: capture, date: date,
                                                sourceBundleID: source.id, sourceName: source.name)
                foreground { [self] in
                    if let duplicate = history.add(entry) { background { [self] in store.delete([duplicate]) } }
                    enforce()
                    save()
                }
            } catch {
                foreground { [self] in
                    problem = localized("A copy could not be saved: %0", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Changing the history

    func setPinned(_ id: UUID, _ pinned: Bool) {
        history.setPinned(id, pinned)
        save()
    }

    func delete(_ id: UUID) {
        guard let removed = history.remove(id) else { return }
        discard([removed])
    }

    func clear(keepingPinned: Bool) {
        discard(history.clear(keepingPinned: keepingPinned))
        // Clear All also takes the indexes once set aside as unreadable:
        // they hold copied text too, and "all" that left them was not all.
        // After `discard`'s work, on the same queue, so the save comes first.
        guard !keepingPinned else { return }
        let kept = history.entries
        background { [self] in store.discardSetAside(keeping: kept) }
    }

    func enforce() {
        let removed = history.enforce(options().limits)
        if !removed.isEmpty { discard(removed) }
    }

    /// The index first, then the files, in one piece of work. The other way
    /// round, a crash in between left an index naming payloads already
    /// deleted -- and after Clear All, the cleared text, which lives in the
    /// index, came back.
    private func discard(_ entries: [ClipboardEntry]) {
        let kept = history.entries
        background { [self] in
            do {
                try store.save(kept)
                store.delete(entries)
            } catch {
                foreground { [self] in
                    problem = localized("The clipboard history could not be saved: %0", error.localizedDescription)
                }
            }
        }
    }

    private func save() {
        let entries = history.entries
        background { [self] in
            do {
                try store.save(entries)
            } catch {
                foreground { [self] in
                    problem = localized("The clipboard history could not be saved: %0", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Restoring

    /// Puts an entry back on the clipboard, ready for ⌘V.
    ///
    /// Remembers the change count the write produced, so the next check
    /// does not capture it as a new copy -- the loop where restoring an
    /// entry adds it again, and again. It does move the entry to the top:
    /// using it again is the most recent thing done with it.
    @discardableResult
    func restore(_ id: UUID) -> ClipboardRestore.Outcome {
        guard let entry = history.entry(id) else { return .failed }
        let (outcome, count) = ClipboardRestore.restore(entry, to: pasteboard) { [store] in store.data($0) }
        guard outcome != .failed else { return outcome }
        ownWrite = count
        lastSeen = count
        var used = entry
        used.date = Date()
        history.add(used)
        save()
        return outcome
    }

    // MARK: - Reading for the views

    func thumbnailURL(_ entry: ClipboardEntry) -> URL? {
        entry.thumbnail.map(store.url(ofFile:))
    }

    func imageURL(_ entry: ClipboardEntry) -> URL? {
        entry.payloads.first { $0.type == ClipboardTypes.png || $0.type == ClipboardTypes.jpeg
                                || $0.type == ClipboardTypes.tiff }
            .map { store.url(ofFile: $0.file) }
    }

    func dismissProblem() { problem = nil }
}
