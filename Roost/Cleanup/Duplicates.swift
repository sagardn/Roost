import CryptoKit
import Foundation

/// Files that are byte-for-byte the same.
///
/// "The same" is decided by content and nothing else: a name, a date or a
/// size can agree by chance, and a duplicate finder that trusts any of them
/// offers somebody's only copy of one file as a spare of another. Two files
/// are duplicates here when they are the same length *and* hash the same
/// with SHA-256 over every byte. Similar photos are not attempted -- "similar"
/// is a judgement, and the cost of a wrong one is a photo.
///
/// Two things look like duplicates and are not, and both were measured on
/// APFS before this was written:
///
/// - **Hard links** are one file under two names. They share a
///   `fileResourceIdentifier`, so they are counted once; trashing either name
///   frees nothing.
/// - **Clones** (Finder's Duplicate, `cp -c`) are two files that share their
///   blocks until one is changed. They share a `fileContentIdentifier`, so
///   they are still shown -- they are two files, and either can go -- but the
///   space a clone gives back is reported as nothing, because that is what
///   it gives back.
///
/// Nothing is ticked for somebody. Which copy to keep is the whole decision,
/// and the one rule enforced here is that it is never "none of them".
enum Duplicates {

    /// Below this, a duplicate is not worth a row: a thousand copies of a
    /// 40 KB icon are 40 MB, and a list of a thousand icons buries the one
    /// video that was copied twice.
    static let minimumBytes: Int64 = 1 << 20

    /// How much of each file is hashed first. Files of equal length that
    /// differ almost always differ in their first block, so this rules most
    /// of them out after one small read instead of a whole one.
    static let headBytes = 64 * 1024

    struct File: Equatable {
        let url: URL
        /// The length, which is what has to match.
        let length: Int64
        /// What it occupies on disk, which is what trashing it gives back.
        let allocated: Int64
        let modified: Date
        /// Which file this is, below its name: two hard links share one.
        let resource: Data?
        /// Which data stream it reads: a clone and its original share one.
        let content: Int64?
        /// Names this file has on the disk. Above one, it has a hard link
        /// somewhere -- often outside the folders compared, where collapsing
        /// links cannot see it -- and trashing this name frees nothing: the
        /// other name still holds the blocks.
        var links: Int = 1

        var name: String { url.lastPathComponent }
        var isLinkedElsewhere: Bool { links > 1 }
    }

    struct Group: Equatable {
        /// Oldest first: the original is usually the first copy made.
        let files: [File]

        var length: Int64 { files.first?.length ?? 0 }

        /// What trashing every copy but one would give back.
        ///
        /// One copy's worth for each *distinct* data stream beyond the first.
        /// Three files where two are clones of each other are two streams,
        /// and give back one file's space, not two.
        ///
        /// A file with another hard link gives back nothing, so it is the copy
        /// to keep, and does not count as a stream that could be freed.
        var reclaimable: Int64 {
            var streams = Set<Int64>()
            var unknown = 0
            for file in files where !file.isLinkedElsewhere {
                if let content = file.content { streams.insert(content) } else { unknown += 1 }
            }
            let distinct = streams.count + unknown
            let keptElsewhere = files.contains(where: \.isLinkedElsewhere)
            let freeable = keptElsewhere ? distinct : max(0, distinct - 1)
            return Int64(freeable) * (files.map(\.allocated).max() ?? 0)
        }

        /// What trashing the `selected` files of this set gives back.
        ///
        /// A data stream's blocks come back only when every file reading it
        /// goes. Two clones of one file, both ticked, free one file's worth;
        /// one of them alone frees nothing. Counting file by file got both
        /// cases wrong in opposite directions.
        func freed(by selected: Set<URL>) -> Int64 {
            var streams: [String: (all: Int, ticked: Int, bytes: Int64)] = [:]
            for file in files {
                let key = file.content.map { "c\($0)" } ?? "u" + file.url.path
                var stream = streams[key] ?? (0, 0, 0)
                stream.all += 1
                if selected.contains(file.url) { stream.ticked += 1 }
                stream.bytes = max(stream.bytes, file.allocated)
                streams[key] = stream
            }
            return streams.values.reduce(0) { $0 + ($1.ticked == $1.all ? $1.bytes : 0) }
                - linkedElsewhere(selected)
        }

        /// What `freed(by:)` counted for ticked files that free nothing,
        /// because each still has another name holding its blocks.
        private func linkedElsewhere(_ selected: Set<URL>) -> Int64 {
            var streams: [String: Int64] = [:]
            for file in files where file.isLinkedElsewhere && selected.contains(file.url) {
                let key = file.content.map { "c\($0)" } ?? "u" + file.url.path
                // Counted only where the whole stream was counted: every
                // file reading it ticked.
                let all = files.filter { ($0.content.map { "c\($0)" } ?? "u" + $0.url.path) == key }
                if all.allSatisfy({ selected.contains($0.url) }) {
                    streams[key] = all.map(\.allocated).max() ?? 0
                }
            }
            return streams.values.reduce(0, +)
        }

        /// Whether trashing `file` alone gives anything back: not when another
        /// file in the group reads the same blocks.
        func freesSpace(_ file: File) -> Bool {
            guard !file.isLinkedElsewhere else { return false }
            guard let content = file.content else { return true }
            return !files.contains { $0.url != file.url && $0.content == content }
        }
    }

    // MARK: - Grouping

    /// Hard links collapsed to one name each -- the first met.
    static func collapsingHardLinks(_ files: [File]) -> [File] {
        var seen = Set<Data>()
        return files.filter { file in
            guard let resource = file.resource else { return true }
            return seen.insert(resource).inserted
        }
    }

    /// The groups among `files`, given a way to hash a file.
    ///
    /// `hash(url, limit)` returns the SHA-256 of the first `limit` bytes, or
    /// of the whole file when `limit` is nil, and nil when the file cannot be
    /// read -- in which case it is left out, never assumed equal. Separated
    /// from the disk so the narrowing can be checked against files that are
    /// written down.
    static func groups(_ files: [File], hash: (URL, Int?) -> Data?,
                       shouldStop: () -> Bool = { false }) -> [Group] {
        let unique = collapsingHardLinks(files)

        var byLength: [Int64: [File]] = [:]
        for file in unique { byLength[file.length, default: []].append(file) }

        var found: [Group] = []
        // Biggest first, so a scan stopped part-way has the groups that matter.
        for length in byLength.keys.sorted(by: >) {
            guard let sameLength = byLength[length], sameLength.count > 1 else { continue }
            if shouldStop() { break }
            for sameHead in split(sameLength, by: { hash($0.url, headBytes) }) {
                let candidates = Int64(headBytes) >= length
                    ? [sameHead]          // the head was the whole file
                    : split(sameHead, by: { hash($0.url, nil) })
                for group in candidates {
                    found.append(Group(files: group.sorted {
                        $0.modified != $1.modified ? $0.modified < $1.modified : $0.url.path < $1.url.path
                    }))
                }
            }
        }
        return found.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable
                                                               : $0.length > $1.length }
    }

    /// `files` split by a key, keeping only splits of two or more. A file
    /// whose key is nil -- one that could not be read -- is dropped.
    private static func split(_ files: [File], by key: (File) -> Data?) -> [[File]] {
        var order: [Data] = []
        var buckets: [Data: [File]] = [:]
        for file in files {
            guard let value = key(file) else { continue }
            if buckets[value] == nil { order.append(value) }
            buckets[value, default: []].append(file)
        }
        return order.compactMap { buckets[$0]!.count > 1 ? buckets[$0] : nil }
    }

    // MARK: - Choosing

    enum Keep { case oldest, newest }

    /// Every copy but the one to keep, for a "select the spares" button.
    static func spares(in group: Group, keeping keep: Keep) -> [URL] {
        guard group.files.count > 1 else { return [] }
        let kept = keep == .oldest ? group.files.first : group.files.last
        return group.files.filter { $0.url != kept?.url }.map(\.url)
    }

    /// Whether `selected` leaves at least one copy of every group in place.
    ///
    /// The one rule this window holds to, checked again on the button that
    /// acts: a tick on every copy is how "remove the duplicates" removes the
    /// file.
    static func keepsACopyOfEach(_ selected: Set<URL>, in groups: [Group]) -> Bool {
        groups.allSatisfy { group in group.files.contains { !selected.contains($0.url) } }
    }

    // MARK: - Hashing

    /// SHA-256 of the first `limit` bytes of a file, or of all of it.
    ///
    /// Read a megabyte at a time, so a 20 GB video is hashed without being
    /// held in memory.
    static func sha256(_ url: URL, limit: Int?) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: min(1 << 20, remaining)),
                      !read.isEmpty else { break }
                chunk = read
            } catch {
                return nil
            }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }
}

// MARK: - Walking the disk

extension Duplicates {

    struct Scan: Equatable {
        var groups: [Group] = []
        var filesSeen = 0
        /// False when the deadline or a stop cut it short. The groups found
        /// are real either way; what is missing is the ones not reached.
        var isComplete = true
    }

    /// Whether to leave a directory out entirely.
    ///
    /// A bundle is one thing, and a duplicate *inside* one -- two copies of a
    /// framework in two apps -- is not somebody's to remove. The same goes
    /// for a project's dependencies and its version control: `node_modules`
    /// is full of identical files by design, and trashing one breaks the
    /// project that needs it.
    static func isWalled(_ url: URL, isPackage: Bool) -> Bool {
        isPackage || LargeFiles.isOpaque(url) || LargeFiles.isSkipped(url)
    }

    /// Duplicates under `roots`. Blocking; off the main thread.
    ///
    /// Bounded by a deadline, like the large-file walk, and for the same
    /// reason. The hashing is bounded too: only files that share a length
    /// with another are read at all. Measured on the Mac this was written on,
    /// the six default folders held 44,336 files; 108 were over a megabyte,
    /// 23 shared a length and had their first block hashed, 19 were hashed
    /// in full, and the whole scan took 1.6 s.
    static func scan(roots: [URL], minimum: Int64 = minimumBytes,
                     deadline: Date = Date().addingTimeInterval(30),
                     shouldStop: () -> Bool = { false },
                     progress: ((Int) -> Void)? = nil) -> Scan {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                      .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .fileResourceIdentifierKey,
                                      .fileContentIdentifierKey, .linkCountKey]
        var result = Scan()
        var files: [File] = []
        func stop() -> Bool { shouldStop() || Date() >= deadline }

        walking: for root in roots {
            guard let walk = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walk {
                result.filesSeen += 1
                if result.filesSeen % LargeFiles.Progress.every == 0 {
                    if stop() { result.isComplete = false; break walking }
                    progress?(result.filesSeen)
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if isWalled(url, isPackage: values.isPackage == true) { walk.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let length = values.fileSize.map(Int64.init), length >= minimum else { continue }
                files.append(File(url: url, length: length,
                                  allocated: Int64(values.totalFileAllocatedSize ?? Int(length)),
                                  modified: values.contentModificationDate ?? .distantPast,
                                  resource: (values.fileResourceIdentifier as? NSData).map { Data($0) },
                                  content: values.fileContentIdentifier,
                                  links: values.linkCount ?? 1))
            }
        }

        result.groups = groups(files, hash: sha256, shouldStop: {
            let stopped = stop()
            if stopped { result.isComplete = false }
            return stopped
        })
        return result
    }

    /// Whether a file is still the one the scan hashed: there, the same
    /// length, not written to since. A copy edited after the scan is no
    /// longer a duplicate of anything, and is refused.
    static func isUnchanged(_ file: File) -> Bool {
        let fresh = URL(fileURLWithPath: file.url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let length = values.fileSize, Int64(length) == file.length,
              let modified = values.contentModificationDate else { return false }
        return abs(modified.timeIntervalSince(file.modified)) < 1
    }
}
