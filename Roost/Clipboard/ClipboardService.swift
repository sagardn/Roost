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
                apply()
            }
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
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        if ClipboardSettings.clearUnpinnedOnQuit {
            store.delete(history.clear(keepingPinned: true))
        }
        try? store.save(history.entries)
        store.close()
    }

    /// Brings everything in line with the settings: the timer on or off,
    /// the store's persistence, the limits.
    func apply() {
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
        if let id = source.id, current.excludedApps.contains(id) {
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
    }

    private func enforce() {
        let removed = history.enforce(options().limits)
        if !removed.isEmpty { discard(removed) }
    }

    private func discard(_ entries: [ClipboardEntry]) {
        background { [self] in store.delete(entries) }
        save()
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
