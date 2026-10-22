import Foundation

/// Finding what is actually taking the space.
///
/// Roost shows things; Finder deletes them. This walks a few folders and
/// reports the biggest items in them, and every one of them opens in Finder
/// rather than being removed here.
///
/// That split is the whole design and it is not timidity. Deleting a user's
/// files is the one mistake that cannot be undone by fixing the bug
/// afterwards, and the folders worth scanning -- Downloads, Documents,
/// Desktop -- are exactly the ones macOS guards, so a delete button would
/// also mean asking a menu bar monitor for permission over somebody's whole
/// home directory. Showing needs the same permission for a moment; keeping
/// it, to delete with, is a different bargain.
enum LargeFiles {

    /// What kind of thing a file is, by extension.
    ///
    /// Extension and nothing else: reading each file to sniff its type would
    /// mean opening every one of a hundred thousand files to draw a list.
    /// The cost of being wrong is a video filed under Other, which is a
    /// cosmetic error in a list somebody is reading anyway.
    enum Category: String, CaseIterable {
        case video, audio, image, archive, installer, document, other

        var title: String {
            switch self {
            case .video:     return localized("Video")
            case .audio:     return localized("Audio")
            case .image:     return localized("Images")
            case .archive:   return localized("Archives")
            case .installer: return localized("Installers")
            case .document:  return localized("Documents")
            case .other:     return localized("Other")
            }
        }

        static let extensions: [Category: Set<String>] = [
            .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
                     "wmv", "flv", "hevc", "prores", "braw", "r3d"],
            .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg",
                     "opus", "alac", "logicx", "band", "caf"],
            .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif",
                     "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "webp",
                     "svg", "bmp"],
            .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
                       "sit", "sitx", "zst"],
            // The one category with a reason to exist beyond sorting: an
            // installer in Downloads has already done its job, and these are
            // large. It is the closest thing to "junk" that is actually
            // true -- unlike a cache, nothing re-creates it and nothing
            // breaks without it.
            .installer: ["dmg", "pkg", "iso", "mpkg", "msi", "appx"],
            .document: ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers",
                        "ppt", "pptx", "key", "epub", "txt", "rtf", "md"]
        ]

        static func of(_ url: URL) -> Category {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return .other }
            for category in Category.allCases where category != .other {
                if extensions[category]?.contains(ext) == true { return category }
            }
            return .other
        }
    }

    struct Item: Equatable {
        let url: URL
        let bytes: Int64

        var name: String { url.lastPathComponent }
        var category: Category { Category.of(url) }

        /// Where it is, relative to home -- "Downloads" or
        /// "Documents/Projects/api". A list of twenty bare file names is a
        /// list nobody can act on; "buf" means nothing and
        /// "Documents/work/api" means everything.
        func folder(relativeTo home: URL) -> String {
            let parent = url.deletingLastPathComponent().path
            let base = home.path
            guard parent.hasPrefix(base) else { return parent }
            let trimmed = String(parent.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "~" : trimmed
        }
    }

    /// The `n` largest, biggest first.
    ///
    /// Separated from the walk so the ranking can be checked against a list
    /// written down. Ties keep the order they arrived in, which for a
    /// directory walk is alphabetical-ish and stable between runs -- a list
    /// that reshuffles two equal files on every scan looks broken.
    static func largest(_ items: [Item], limit: Int) -> [Item] {
        guard limit > 0 else { return [] }
        return Array(items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.bytes != rhs.element.bytes
                    ? lhs.element.bytes > rhs.element.bytes
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
            .prefix(limit))
    }

    /// Bytes per category, largest first, with empty categories left out.
    ///
    /// What the cleaner's bar is drawn from. Ties fall back to the order the
    /// categories are declared in, for the same reason `largest` keeps ties
    /// stable: a bar whose segments swap places between scans looks broken.
    static func breakdown(_ items: [Item]) -> [(category: Category, bytes: Int64)] {
        var totals: [Category: Int64] = [:]
        for item in items { totals[item.category, default: 0] += item.bytes }
        // A loop and a stable insertion, not a chain of enumerated / compactMap
        // / sorted over tuples: that chain took 1175ms to type-check, which is
        // the shape that once kept a suite from compiling on CI at all.
        var parts: [(category: Category, bytes: Int64)] = []
        for category in Category.allCases {
            guard let bytes = totals[category] else { continue }
            let index = parts.firstIndex { $0.bytes < bytes } ?? parts.count
            parts.insert((category: category, bytes: bytes), at: index)
        }
        return parts
    }

    /// Whether to treat a directory as one item and stop descending.
    ///
    /// A `.app`, a `.photoslibrary` or an `.xcodeproj` is one thing to the
    /// person looking at it. Walking inside and reporting its twenty largest
    /// parts answers a question nobody asked and buries the real answer --
    /// which is that the bundle itself is large.
    static let opaqueExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "sparsebundle", "bundle", "framework",
        "xcodeproj", "xcworkspace", "rtfd", "download"
    ]

    /// Directories that are one thing to a person, whatever they hold.
    ///
    /// A developer's Mac has thousands of files inside `node_modules` and
    /// `.git`, and the first run of this filled all twenty rows with them --
    /// `rolldown-binding.win32-x64-msvc.node` and its siblings, 30 MB each,
    /// burying every file somebody might actually act on. The useful answer
    /// is not twenty dependencies, it is "this project's node_modules is
    /// 2 GB", which is one row.
    ///
    /// They are reported, not hidden: the space is real and deleting a
    /// `node_modules` is a normal thing to do. It is one line instead of
    /// twenty.
    static let opaqueDirectories: Set<String> = [
        "node_modules", ".git", ".svn", "Pods", "Carthage", "DerivedData",
        ".build", "build", "target", "vendor", "__pycache__", ".venv", "venv",
        ".gradle", ".next", ".nuxt", "dist", ".cargo", ".rustup", ".npm"
    ]

    static func isOpaque(_ url: URL) -> Bool {
        if opaqueDirectories.contains(url.lastPathComponent) { return true }
        return opaqueExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether to leave a path alone entirely.
    ///
    /// Not a judgement about what is junk -- there is no such judgement that
    /// survives a real disk. These are the places where a size is either
    /// meaningless or misleading: the snapshot mount macOS keeps, anything
    /// not on this volume, and the caches a report would invite somebody to
    /// delete when deleting them only makes the next hour slower.
    static func isSkipped(_ url: URL) -> Bool {
        let path = url.path
        if path.hasPrefix("/System/Volumes") { return true }
        if path.contains("/.Trash") { return true }
        if path.contains("/Library/Caches/") { return true }
        return false
    }

    /// The folders worth offering to look in.
    ///
    /// Each one is somewhere people actually accumulate large files. They are
    /// also each TCC-guarded, so the first scan prompts -- which is the
    /// honest shape: the person is asked about the folder they just asked to
    /// have searched.
    static func defaultRoots(home: URL) -> [URL] {
        ["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
    }
}

// MARK: - Walking the disk

extension LargeFiles {

    /// The biggest items under `roots`.
    ///
    /// Bounded by a deadline rather than trusting the walk to be quick: a
    /// Pictures folder can hold a hundred thousand files, and a scan that
    /// takes a minute on somebody else's Mac is a scan that looks hung. What
    /// it has found when time runs out is still the right answer for the part
    /// it reached, which is better than nothing and much better than a beach
    /// ball.
    ///
    /// Blocking, and meant to be called off the main thread.
    ///
    /// `progress` is called on the scanning thread, at each root and then
    /// every `Progress.every` files -- not per file, because a hundred
    /// thousand main-thread hops cost more than the walk they report on.
    /// `shouldStop` is polled at the same points as the deadline, so a
    /// cancelled scan returns what it had rather than finishing first.
    static func scan(roots: [URL], limit: Int = 20,
                     deadline: Date = Date().addingTimeInterval(8),
                     shouldStop: () -> Bool = { false },
                     progress: ((Progress) -> Void)? = nil) -> [Item] {
        let fm = FileManager.default
        var found: [Item] = []
        var report = Progress()

        for (index, root) in roots.enumerated() {
            guard Date() < deadline, !shouldStop() else { break }
            guard !isSkipped(root) else { continue }

            report.root = index
            progress?(report)

            // `skipsHiddenFiles` because a dotfile is not what anybody means
            // by a large file, and because it keeps the walk out of the
            // version-control and cache directories that live in them.
            guard let walk = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey,
                                             .totalFileAllocatedSizeKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }   // an unreadable folder is skipped, not fatal
            ) else { continue }

            for case let url as URL in walk {
                if Date() >= deadline { break }
                report.files += 1
                if report.files % Progress.every == 0 {
                    if shouldStop() { break }
                    report.folder = url.deletingLastPathComponent().lastPathComponent
                    progress?(report)
                }

                if isSkipped(url) {
                    walk.skipDescendants()
                    continue
                }

                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .totalFileAllocatedSizeKey, .isPackageKey])

                let isDirectory = values?.isDirectory ?? false
                let isBundle = (values?.isPackage ?? false) || isOpaque(url)

                if isDirectory && isBundle {
                    // One item, not its contents.
                    walk.skipDescendants()
                    if let size = directorySize(of: url, fm: fm, deadline: deadline,
                                                shouldStop: shouldStop), size > 0 {
                        found.append(Item(url: url, bytes: size))
                        report.bytes += size
                    }
                    continue
                }
                if isDirectory { continue }

                if let size = values?.totalFileAllocatedSize, size > 0 {
                    found.append(Item(url: url, bytes: Int64(size)))
                    report.bytes += Int64(size)
                }
            }
        }

        report.root = roots.count
        progress?(report)
        return largest(found, limit: limit)
    }

    /// How far a scan has got, for something to draw while it works.
    struct Progress: Equatable {
        /// Often enough that the count visibly climbs, rarely enough that
        /// reporting stays a rounding error on the walk.
        static let every = 250

        /// Index into the roots being walked; equal to their count once done.
        var root = 0
        var files = 0
        /// Everything seen so far, not just what will make the list.
        var bytes: Int64 = 0
        /// The folder the walk is in, by name, for a line of status.
        var folder = ""
    }

    /// What a bundle adds up to, with the same deadline over it.
    /// nil when the measuring was cut short, by Stop or the deadline.
    ///
    /// It used to check only the deadline, so Stop waited on a Photos
    /// library being measured for up to the whole 45 seconds -- and a bundle
    /// the deadline cut off was listed at the size reached so far, as though
    /// that were all of it. A size on this list is one somebody may act on;
    /// half of one is left off instead.
    private static func directorySize(of url: URL, fm: FileManager, deadline: Date,
                                      shouldStop: () -> Bool) -> Int64? {
        guard let walk = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [], errorHandler: { _, _ in true }) else { return nil }

        var total: Int64 = 0
        var seen = 0
        for case let child as URL in walk {
            seen += 1
            // Every 256 entries: a bundle can hold hundreds of thousands,
            // and the clock and the flag need not be read for each.
            if seen % 256 == 0, Date() >= deadline || shouldStop() { return nil }
            total += Int64((try? child.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

// MARK: - Removing what was chosen

extension LargeFiles {

    /// What came of moving a set of files to the Bin.
    struct Removal: Equatable {
        var moved: [URL] = []
        var failed: [URL] = []
        /// Why the first failure failed, in words, for the message.
        var reason: String?

        var bytesFreed: Int64 = 0
        var isCompleteSuccess: Bool { failed.isEmpty && !moved.isEmpty }
    }

    /// Moves files to the Bin.
    ///
    /// **To the Bin, never `removeItem`.** The difference is the whole reason
    /// this is allowed to exist inside a monitoring app: a file in the Bin is
    /// a mistake somebody can undo in Finder, and a file passed to
    /// `removeItem` is a mistake nobody can undo at all. Every bug in the
    /// ranking, the selection or the hit testing above becomes recoverable at
    /// this one line, so it is the line that does not change.
    ///
    /// Partial failure is normal rather than exceptional -- a file can be
    /// locked, in use, or on a volume with no Bin -- so each is reported
    /// rather than the whole batch failing on the first.
    static func moveToBin(_ items: [Item]) -> Removal {
        var result = Removal()
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                result.moved.append(item.url)
                result.bytesFreed += item.bytes
            } catch {
                result.failed.append(item.url)
                if result.reason == nil { result.reason = reason(for: error) }
            }
        }
        return result
    }

    /// Why a move failed, as something a person can act on.
    ///
    /// "3 moved, 2 could not be" left them to guess whether to retry, quit
    /// something or give up. The three causes worth naming are the ones
    /// with different answers; anything else is said in macOS's words.
    static func reason(for error: Error) -> String {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? $0.code : nil
        }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError || posix == Int(ENOENT) {
            return localized("it was already gone")
        }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
            || posix == Int(EPERM) || posix == Int(EACCES) {
            return localized("macOS did not allow it — it may be in use or protected")
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFeatureUnsupportedError {
            return localized("its disk has no Bin")
        }
        return ns.localizedDescription
    }

    /// What to say afterwards.
    static func message(for removal: Removal) -> String {
        if removal.moved.isEmpty {
            guard let reason = removal.reason else { return localized("Nothing could be moved to the Bin") }
            return localized("Nothing could be moved to the Bin: %0", reason)
        }
        if removal.failed.isEmpty {
            return localized("%0 moved to the Bin", String(removal.moved.count))
        }
        guard let reason = removal.reason else {
            return localized("%0 moved, %1 could not be",
                             String(removal.moved.count), String(removal.failed.count))
        }
        return localized("%0 moved, %1 could not be: %2",
                         String(removal.moved.count), String(removal.failed.count), reason)
    }
}

// MARK: - Folders

extension LargeFiles {

    /// What was found, arranged by where it lives.
    ///
    /// The flat list repeats the same long path on row after row -- forty
    /// results measured here came from nine folders, one of them
    /// `~/Desktop/project/shield/nocapdash-next/node_modules`, written out in
    /// full six times. Grouped, each folder appears once with its total,
    /// which is also the more useful answer: a project's build output is one
    /// decision, not six.
    struct Folder: Equatable {
        /// What the row says. Usually one path component; several, joined
        /// with "/", where a chain of folders held nothing but each other.
        var name: String
        var url: URL
        var folders: [Folder] = []
        var files: [Item] = []
        /// Everything beneath, at any depth.
        var bytes: Int64 = 0
        var count: Int = 0

        /// Every file beneath, at any depth -- what ticking the folder ticks.
        var allFiles: [Item] { files + folders.flatMap(\.allFiles) }
    }

    /// The tree of `items`, rooted at `base`.
    ///
    /// Two rules shape it, and both are about what a person scans:
    ///
    /// - **Biggest first, folders before files**, at every level, with ties
    ///   in arrival order -- the same stability `largest` keeps.
    /// - **Chains collapse.** A folder whose only content is one other folder
    ///   is not a decision anybody makes, and three levels of disclosure
    ///   triangles to reach `project/shield/code` is three clicks of nothing.
    ///   Such folders merge into one row named by the joined path. The root's
    ///   own children never merge into it, so Desktop, Documents and
    ///   Downloads stay recognisable at the top.
    ///
    /// A file outside `base` is placed by its absolute path, so nothing found
    /// is ever dropped from the tree.
    static func tree(_ items: [Item], under base: URL) -> Folder {
        final class Node {
            let url: URL
            var order: [String] = []
            var children: [String: Node] = [:]
            var files: [Item] = []
            init(_ url: URL) { self.url = url }
            func child(_ name: String) -> Node {
                if let found = children[name] { return found }
                let made = Node(url.appendingPathComponent(name, isDirectory: true))
                children[name] = made
                order.append(name)
                return made
            }
        }

        let basePath = base.standardizedFileURL.path
        let root = Node(base)
        for item in items {
            let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
            let relative: String
            if parent == basePath {
                relative = ""
            } else if parent.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") {
                relative = String(parent.dropFirst(basePath.count))
            } else {
                relative = parent
            }
            var node = root
            for part in relative.split(separator: "/") { node = node.child(String(part)) }
            node.files.append(item)
        }

        func build(_ node: Node, name: String, isRoot: Bool) -> Folder {
            var folders = node.order.map { build(node.children[$0]!, name: $0, isRoot: false) }
            let files = largest(node.files, limit: node.files.count)

            var folder = Folder(name: name, url: node.url)
            if !isRoot, files.isEmpty, folders.count == 1 {
                let only = folders.removeFirst()
                folder = only
                folder.name = name + "/" + only.name
                return folder
            }
            folders = Array(folders.enumerated()
                .sorted { $0.element.bytes != $1.element.bytes
                            ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset }
                .map(\.element))
            folder.folders = folders
            folder.files = files
            folder.bytes = files.reduce(0) { $0 + $1.bytes } + folders.reduce(0) { $0 + $1.bytes }
            folder.count = files.count + folders.reduce(0) { $0 + $1.count }
            return folder
        }

        return build(root, name: "~", isRoot: true)
    }

    /// One visible line of a tree: a folder or a file, and how deep it sits.
    enum Line: Equatable {
        case folder(Folder, depth: Int)
        case file(Item, depth: Int)

        var id: URL {
            switch self {
            case .folder(let folder, _): return folder.url
            case .file(let item, _):     return item.url
            }
        }
    }

    /// The tree's lines, top to bottom, with only `expanded` folders open.
    ///
    /// The root itself is not a line: "~" over everything is a row that can
    /// only ever be open.
    static func lines(_ root: Folder, expanded: Set<URL>) -> [Line] {
        var out: [Line] = []
        func walk(_ folder: Folder, depth: Int) {
            for child in folder.folders {
                out.append(.folder(child, depth: depth))
                if expanded.contains(child.url) { walk(child, depth: depth + 1) }
            }
            for file in folder.files { out.append(.file(file, depth: depth)) }
        }
        walk(root, depth: 0)
        return out
    }
}
