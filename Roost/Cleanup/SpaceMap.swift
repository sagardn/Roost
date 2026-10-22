import CoreGraphics
import Foundation

/// What a folder is made of, by size, all the way down.
///
/// The large-file list answers "which files are big"; this answers "where
/// did the space go", which is usually a different question with a different
/// answer -- 40,000 files of a few hundred kilobytes each make no row in a
/// list of the twenty biggest and can still be the biggest thing on the disk.
///
/// The walk keeps only what can be drawn. Each folder keeps its `keep`
/// largest children and folds the rest into one "smaller items" entry, so a
/// home folder of a million files becomes a tree of a few thousand nodes
/// rather than a million of them in memory. Folding loses no bytes: a folded
/// entry carries the total of everything folded into it. A hard-linked file
/// is counted once per name, as Finder's Get Info counts it, so a tree full
/// of hard links reads larger than the blocks it uses.
///
/// The map itself deletes nothing. What it offers to remove is decided here,
/// in `isRemovable`, `collapsed` and `isUnchanged`, and moved by the page,
/// which asks first -- see the Removing section below.
enum SpaceMap {

    enum Kind: Equatable {
        case folder
        /// An app, a library, a bundle: one thing to the person, measured
        /// whole and never opened up.
        case package
        case file
        /// Everything in a folder below its `keep` largest, as one entry.
        case smaller(count: Int)
        /// A folder that could not be opened. Its size is unknown, not zero.
        case unreadable
        /// A folder deliberately not measured, and why is `SpaceMap.notMeasured`.
        case skipped
    }

    struct Node: Equatable {
        var name: String
        let url: URL
        var kind: Kind
        var bytes: Int64
        var children: [Node] = []
        /// Folders beneath that could not be opened, at any depth.
        var unreadable = 0
        /// True when the deadline or a stop cut this folder's walk short.
        var isPartial = false
        /// Measured, but its contents dropped as too small to draw. Opening
        /// it walks it again; see `pruned`.
        var isCollapsed = false
        /// A file's modification date when it was measured, so a removal
        /// minutes later can tell it is still the file that was shown.
        var modified: Date?

        var isFolder: Bool { kind == .folder }
    }

    /// How many children a folder keeps before folding the rest. Enough for
    /// a map to be worth reading; a 60th rectangle is a hairline nobody can
    /// click.
    static let keep = 40

    /// The rest, folded: the `keep` largest kept, biggest first, ties in
    /// name order so a rescan does not reshuffle equal folders.
    static func folded(_ children: [Node], keep: Int = keep, parent: URL) -> [Node] {
        let sorted = children.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes
                                 : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard sorted.count > keep else { return sorted }
        let rest = sorted[keep...]
        var count = 0
        for node in rest {
            if case .smaller(let inner) = node.kind { count += inner } else { count += 1 }
        }
        let folded = Node(name: "", url: parent.appendingPathComponent(".roost-smaller-items"),
                          kind: .smaller(count: count), bytes: rest.reduce(0) { $0 + $1.bytes })
        return Array(sorted.prefix(keep)) + [folded]
    }

    /// The folders a walk of a home folder does not go into.
    ///
    /// Since macOS 14, reading inside another app's container asks the person
    /// whether Roost may "access data from other apps" -- once per app, and a
    /// home folder holds hundreds of them. A map that opens with a cascade of
    /// permission sheets is not one anybody uses. They stay in the tree as
    /// `.skipped` nodes of unknown size, and the window names them under the
    /// map, so the gap is said rather than looking like nothing was there.
    static func notMeasured(home: URL) -> Set<String> {
        ["Library/Containers", "Library/Group Containers"].map {
            home.appendingPathComponent($0).standardizedFileURL.path
        }.reduce(into: Set<String>()) { $0.insert($1) }
    }
}

// MARK: - Walking

extension SpaceMap {

    struct Progress: Equatable {
        var files = 0
        var bytes: Int64 = 0
        var folder = ""
    }

    struct Result: Equatable {
        var root: Node
        /// The folders deliberately not opened, recorded as the walk meets
        /// them rather than read back out of the tree -- pruning can drop
        /// the folder they sit in, and the note under the map must not go
        /// with it.
        var notMeasured: [URL] = []
    }

    /// The tree under `root`. Blocking; off the main thread.
    ///
    /// Stays on `root`'s volume: a mounted disk image or network share inside
    /// the folder is another disk, and adding it in would make a 256 GB disk
    /// appear to hold a terabyte. Symlinks count as themselves, not as what
    /// they point at, for the same reason.
    static func scan(_ root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     deadline: Date = Date().addingTimeInterval(60),
                     shouldStop: () -> Bool = { false },
                     progress: ((Progress) -> Void)? = nil) -> Result {
        let skipped = notMeasured(home: home)
        var met: [URL] = []
        let volume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
            as? NSObject
        var report = Progress()
        var stopped = false

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .totalFileAllocatedSizeKey, .volumeIdentifierKey,
                                      .contentModificationDateKey]

        func walk(_ url: URL, name: String) -> Node {
            if stopped || shouldStop() || Date() >= deadline {
                stopped = true
                return Node(name: name, url: url, kind: .folder, bytes: 0, isPartial: true)
            }
            if skipped.contains(url.standardizedFileURL.path) {
                met.append(url)
                return Node(name: name, url: url, kind: .skipped, bytes: 0)
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []) else {
                return Node(name: name, url: url, kind: .unreadable, bytes: 0, unreadable: 1)
            }

            var children: [Node] = []
            var unreadable = 0
            var partial = false
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { continue }
                if let volume, let here = values.volumeIdentifier as? NSObject, !here.isEqual(volume) {
                    continue
                }
                if values.isDirectory == true {
                    if values.isPackage == true {
                        let bytes = packageSize(entry)
                        children.append(Node(name: entry.lastPathComponent, url: entry,
                                             kind: .package, bytes: bytes))
                        report.bytes += bytes
                    } else {
                        let child = walk(entry, name: entry.lastPathComponent)
                        unreadable += child.unreadable
                        partial = partial || child.isPartial
                        children.append(child)
                    }
                } else {
                    let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                    children.append(Node(name: entry.lastPathComponent, url: entry,
                                         kind: .file, bytes: bytes,
                                         modified: values.contentModificationDate))
                    report.bytes += bytes
                    report.files += 1
                    if report.files % LargeFiles.Progress.every == 0 {
                        report.folder = name
                        progress?(report)
                    }
                }
            }
            let total = children.reduce(Int64(0)) { $0 + $1.bytes }
            return Node(name: name, url: url, kind: .folder, bytes: total,
                        children: folded(children, parent: url), unreadable: unreadable,
                        isPartial: partial || stopped)
        }

        let tree = walk(root, name: root.lastPathComponent)
        progress?(report)
        return Result(root: pruned(tree, below: tree.bytes / pruneDivisor), notMeasured: met)
    }

    /// A folder smaller than the root over this keeps its total and drops
    /// its contents.
    ///
    /// Folding alone was not enough. Measured on a 64 GB home folder, keeping
    /// forty children per folder still kept 530,210 nodes, nearly all of
    /// them folders of a few kilobytes deep inside `node_modules` and caches
    /// -- each one a rectangle under a hundredth of a point at any depth
    /// anybody could open it to. At 1/2000 of the root, the smallest folder
    /// that keeps its contents is a 32 MB one on that disk, and opening a
    /// smaller one walks just that folder again, which is quick because it
    /// is small.
    static let pruneDivisor: Int64 = 2000

    static func pruned(_ node: Node, below minimum: Int64) -> Node {
        guard node.isFolder, !node.children.isEmpty else { return node }
        var copy = node
        if node.bytes < minimum {
            copy.children = []
            copy.isCollapsed = true
            return copy
        }
        copy.children = node.children.map { pruned($0, below: minimum) }
        return copy
    }

    /// A bundle's size, measured whole. Its own walk, not the tree's, because
    /// nothing inside it is drawn.
    private static func packageSize(_ url: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walk {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// `root` with the folder at `url` replaced by `node` -- how a collapsed
    /// folder, walked again when it is opened, goes back into the map. The
    /// totals above it are unchanged: the folder was already measured, and
    /// walking it again only fills in what is inside.
    static func replacing(_ url: URL, with node: Node, in root: Node) -> Node {
        if root.url.standardizedFileURL == url.standardizedFileURL { return node }
        let target = url.standardizedFileURL.path
        var copy = root
        copy.children = root.children.map { child in
            guard child.isFolder else { return child }
            let path = child.url.standardizedFileURL.path
            return target == path || target.hasPrefix(path + "/") ? replacing(url, with: node, in: child) : child
        }
        return copy
    }

    /// The node at `path` below `root`, following children by URL.
    static func node(at url: URL, in root: Node) -> Node? {
        if root.url.standardizedFileURL == url.standardizedFileURL { return root }
        let target = url.standardizedFileURL.path
        for child in root.children where child.isFolder {
            let path = child.url.standardizedFileURL.path
            if target == path || target.hasPrefix(path + "/") { return node(at: url, in: child) }
        }
        return nil
    }
}

// MARK: - Removing

extension SpaceMap {

    /// A home folder's own folders. Each is where a kind of thing lives, not a
    /// thing, and the Bin is no place for Documents however large it is.
    static let homeFolders: Set<String> = ["Applications", "Desktop", "Documents", "Downloads",
                                           "Library", "Movies", "Music", "Pictures", "Public"]

    /// Whether a box can be ticked against this entry.
    ///
    /// Inside the home folder or on another disk, and nowhere else: the rest
    /// of a startup volume is the system's or an installer's, and an app in
    /// /Applications is the Uninstaller's to remove, with what it left behind. Never anything
    /// in ~/Library either, even though a map shows it -- one row there is a
    /// whole `Application Support` folder, somebody's mail or photo library,
    /// and the Check-up and AI tools are where that folder is taken apart
    /// with rules about what is safe. And never the folder being mapped, the
    /// home folder, one of its own folders, or an entry that stands for
    /// something rather than being it: "smaller items", a folder that could
    /// not be opened, one deliberately not measured.
    ///
    /// Nor a folder the walk did not finish. Stopped, or out of time, the
    /// walk leaves those at the size it had reached -- often zero -- and the
    /// confirmation then asked "Move Zero KB to the Bin?" of a folder that
    /// might hold gigabytes. A size somebody is asked to agree to has to be
    /// the real one.
    static func isRemovable(_ node: Node, root: URL, home: URL) -> Bool {
        guard !node.isPartial else { return false }
        switch node.kind {
        case .file, .folder, .package: break
        case .smaller, .unreadable, .skipped: return false
        }
        let path = node.url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path != root.standardizedFileURL.path, path != homePath else { return false }

        if path.hasPrefix(homePath + "/") {
            let parts = path.dropFirst(homePath.count + 1).split(separator: "/")
            guard let first = parts.first.map(String.init) else { return false }
            if first == "Library" { return false }
            return !(parts.count == 1 && homeFolders.contains(first))
        }
        // Another disk, but not the disk itself.
        let inVolumes = path.hasPrefix("/Volumes/")
        return inVolumes && path.split(separator: "/").count > 2
    }

    /// The ticked entries with anything inside another ticked one left out.
    ///
    /// A folder and a file inside it both ticked is one removal, not two:
    /// moving the folder takes the file with it, and trying the file
    /// afterwards would report it as having failed.
    static func collapsed(_ urls: Set<URL>) -> [URL] {
        let sorted = urls.map(\.standardizedFileURL).sorted { $0.path < $1.path }
        var kept: [URL] = []
        for url in sorted where !kept.contains(where: { url.path.hasPrefix($0.path + "/") }) {
            kept.append(url)
        }
        return kept
    }

    /// Whether an entry is still what the map measured.
    ///
    /// A map can be minutes old by the time somebody acts on it. A file must
    /// still be the same size and carry the same modification date; anything
    /// else must still exist. A folder's total is not measured again -- that
    /// is a walk of its own -- so a folder is trusted to be the one that was
    /// shown if it is still there.
    static func isUnchanged(_ node: Node) -> Bool {
        let fresh = URL(fileURLWithPath: node.url.path)
        guard node.kind == .file else {
            return FileManager.default.fileExists(atPath: fresh.path)
        }
        guard let values = try? fresh.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                               .contentModificationDateKey]),
              let size = values.totalFileAllocatedSize, Int64(size) == node.bytes else { return false }
        guard let then = node.modified, let now = values.contentModificationDate else {
            return node.modified == nil && values.contentModificationDate == nil
        }
        return abs(now.timeIntervalSince(then)) < 1
    }

    /// The tree with these entries gone and every folder above them smaller
    /// by what they held, so the map stops drawing space that is in the Bin.
    static func removing(_ gone: Set<URL>, from node: Node) -> Node {
        guard !node.children.isEmpty else { return node }
        var copy = node
        var lost: Int64 = 0
        var kept: [Node] = []
        for child in node.children {
            if gone.contains(child.url.standardizedFileURL) {
                lost += child.bytes
                continue
            }
            let updated = removing(gone, from: child)
            lost += child.bytes - updated.bytes
            kept.append(updated)
        }
        copy.children = kept
        copy.bytes -= lost
        return copy
    }
}

// MARK: - The map

extension SpaceMap {

    /// Rectangles for `sizes`, in order, filling `rect`, each with an area in
    /// proportion to its size.
    ///
    /// Squarified (Bruls, Huizing and van Wijk, 2000): items are laid in rows
    /// along the shorter side, and a row is closed as soon as adding the next
    /// item would make its worst aspect ratio worse. The slice-and-dice layout
    /// is simpler and gives every small folder a one-point sliver, which is a
    /// rectangle nobody can read or hit.
    ///
    /// `sizes` must be biggest first, which is how `folded` hands them over.
    /// Zero and negative sizes get an empty rectangle rather than none, so
    /// the result always lines up with the input.
    static func squarify(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { max(0, $0) * scale }
        var free = rect
        var start = 0

        /// The worst aspect ratio of a row of `row` areas laid along `side`.
        func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0, let biggest = row.max(), let smallest = row.min(), smallest > 0
            else { return .infinity }
            let s2 = side * side, sum2 = sum * sum
            return max(s2 * biggest / sum2, sum2 / (s2 * smallest))
        }

        while start < areas.count {
            guard areas[start] > 0 else { start += 1; continue }
            let side = Double(min(free.width, free.height))
            var end = start + 1
            while end < areas.count, areas[end] > 0,
                  worst(areas[start...end], side: side) <= worst(areas[start..<end], side: side) {
                end += 1
            }
            let row = areas[start..<end]
            let sum = row.reduce(0, +)
            let horizontal = free.width >= free.height   // the row is a column on the left
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            for index in start..<end {
                let length = CGFloat(areas[index] / sum) * CGFloat(side)
                result[index] = horizontal
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                offset += length
            }
            if horizontal {
                free = CGRect(x: free.minX + thickness, y: free.minY,
                              width: max(0, free.width - thickness), height: free.height)
            } else {
                free = CGRect(x: free.minX, y: free.minY + thickness,
                              width: free.width, height: max(0, free.height - thickness))
            }
            start = end
        }
        return result
    }
}
