import Foundation

/// The rules of the history, with no clipboard and no disk in them.
///
/// What gets kept, in what order, for how long, and what a search finds.
/// Kept apart from the store and the monitor so each rule can be checked
/// against values written down -- see Tools/clipboard-test.swift.
struct ClipboardHistory: Equatable {

    /// Newest first.
    private(set) var entries: [ClipboardEntry] = []

    struct Limits: Equatable {
        /// Unpinned entries kept at most. Pinned ones do not count against
        /// it: pinning is "keep this", and a limit that pushed pins out
        /// would make it mean "keep this for now".
        var maximumEntries: Int
        /// Unpinned entries older than this go. nil keeps them until the
        /// count pushes them out.
        var retention: TimeInterval?
        /// Whether pinned entries are subject to `retention` too. Off by
        /// default, and only ever on because somebody chose it.
        var retentionIncludesPinned: Bool = false
    }

    init(entries: [ClipboardEntry] = []) {
        self.entries = entries.sorted { $0.date > $1.date }
    }

    // MARK: - Adding

    /// Adds an entry, or -- when it is the same content as the newest one --
    /// moves the newest forward to now instead of adding a second copy.
    ///
    /// Only the newest is compared. Copying A, then B, then A again is three
    /// copies somebody made, and the second A belongs at the top; copying A
    /// twice in a row is one. An older identical entry is moved up rather
    /// than duplicated, though, so the list never holds the same thing twice.
    ///
    /// Returns the entry that was dropped as a duplicate, whose files the
    /// caller deletes, if any.
    @discardableResult
    mutating func add(_ entry: ClipboardEntry) -> ClipboardEntry? {
        if let index = entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            var kept = entries.remove(at: index)
            kept.date = entry.date
            // A newer source is the better guess at where it came from.
            kept.sourceBundleID = entry.sourceBundleID ?? kept.sourceBundleID
            kept.sourceName = entry.sourceName ?? kept.sourceName
            entries.insert(kept, at: 0)
            return entry
        }
        entries.insert(entry, at: 0)
        return nil
    }

    // MARK: - Limits

    /// Applies the limits, returning what was removed so its files can go.
    @discardableResult
    mutating func enforce(_ limits: Limits, now: Date = Date()) -> [ClipboardEntry] {
        var removed: [ClipboardEntry] = []
        if let retention = limits.retention {
            let cutoff = now.addingTimeInterval(-retention)
            removed += entries.filter { $0.date < cutoff && (!$0.isPinned || limits.retentionIncludesPinned) }
        }
        let survivors = entries.filter { entry in !removed.contains { $0.id == entry.id } }
        var unpinnedSeen = 0
        var kept: [ClipboardEntry] = []
        for entry in survivors {
            if entry.isPinned {
                kept.append(entry)
            } else if unpinnedSeen < max(0, limits.maximumEntries) {
                unpinnedSeen += 1
                kept.append(entry)
            } else {
                removed.append(entry)
            }
        }
        entries = kept
        return removed
    }

    // MARK: - Changing one

    mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned = pinned
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> ClipboardEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    /// Everything, or everything not pinned. Returns what went.
    @discardableResult
    mutating func clear(keepingPinned: Bool) -> [ClipboardEntry] {
        let removed = keepingPinned ? entries.filter { !$0.isPinned } : entries
        entries = keepingPinned ? entries.filter(\.isPinned) : []
        return removed
    }

    func entry(_ id: UUID) -> ClipboardEntry? { entries.first { $0.id == id } }

    // MARK: - Finding

    enum Filter: String, CaseIterable {
        case all, text, images, pinned
    }

    /// The entries a filter and a search leave, newest first.
    ///
    /// The search is case- and diacritic-insensitive and matches every word
    /// typed, in any order, against the text, the source app and the kind --
    /// so an image, which has no text, is still found by "image", by the app
    /// it was copied in, or by its size.
    func matching(_ query: String, filter: Filter) -> [ClipboardEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            switch filter {
            case .all:    break
            case .text:   guard entry.kind != .image && entry.kind != .files else { return false }
            case .images: guard entry.kind == .image else { return false }
            case .pinned: guard entry.isPinned else { return false }
            }
            guard !words.isEmpty else { return true }
            let haystack = Self.searchable(entry)
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private static func searchable(_ entry: ClipboardEntry) -> String {
        [entry.text, entry.sourceName, entry.kind.rawValue,
         entry.kind == .image ? "image picture" : nil, entry.pixelSize]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// Total bytes stored, for the settings page.
    var byteSize: Int { entries.reduce(0) { $0 + $1.byteSize } }
}

/// A short, one-line description of an entry for a list row.
enum ClipboardPreview {
    /// The first non-blank line, whitespace collapsed, cut at `limit`
    /// characters with an ellipsis. A list row is one line; a two-megabyte
    /// log pasted into it would be a row two megabytes long.
    static func line(_ text: String, limit: Int = 160) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? text
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// How many more lines there are beyond the first, for "+12 lines".
    static func extraLines(_ text: String) -> Int {
        max(0, text.split(whereSeparator: \.isNewline).count - 1)
    }
}
