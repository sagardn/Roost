import Foundation

/// What in Downloads has already done its job: installers that have been
/// run, and downloads that never finished.
///
/// These are the two things in a Downloads folder that are junk by what they
/// *are* rather than by a guess about whether somebody wants them. An
/// installer's app is installed or it is not, and either way the disk image
/// is not what runs it; a `.crdownload` from last month is a file no browser
/// will ever resume. Everything else in Downloads -- a PDF, a photo, a zip --
/// is somebody's, and the Large files window is where it is shown.
///
/// Only the top of the folder. An installer somebody filed into a subfolder
/// was filed deliberately, and that is a decision this should not second-guess.
enum StaleDownloads {

    enum Kind: Equatable {
        case installer
        case incomplete
    }

    /// Disk images and packages. `.iso` is left out: it is as often a
    /// virtual machine's disk somebody boots as an installer somebody ran.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// What each browser names a download while it is still arriving:
    /// Safari's `.download` bundle, Chrome's and Edge's `.crdownload`,
    /// Firefox's `.part`, Opera's `.opdownload`, and the `.partial` older
    /// Edge builds used.
    static let incompleteExtensions: Set<String> = ["download", "crdownload", "part",
                                                    "partial", "opdownload"]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if installerExtensions.contains(ext) { return .installer }
        if incompleteExtensions.contains(ext) { return .incomplete }
        return nil
    }

    struct Item: Equatable {
        let url: URL
        let kind: Kind
        let bytes: Int64
        /// When it arrived in Downloads, or was last written if macOS has no
        /// record of that.
        let added: Date
        /// The modification date at the scan, checked again before the Bin.
        let modified: Date

        var name: String { url.lastPathComponent }
    }

    /// How long a partial download has to sit untouched before it counts as
    /// abandoned. A download in progress writes every second; one paused
    /// overnight is still somebody's. A day is past both.
    static let abandonedAfter: TimeInterval = 86_400

    /// How long an installer has to have been in Downloads to be ticked. A
    /// disk image from this week may be one somebody has not opened yet;
    /// one from a month ago has been used or forgotten, and either way it is
    /// one download away from coming back.
    static let installerTickedAfter: TimeInterval = 30 * 86_400

    /// Whether it is offered at all.
    ///
    /// A partial download written in the last day may still be arriving, and
    /// trashing it would break a download in progress. An installer that is
    /// mounted right now is open in Finder, possibly mid-install.
    static func isOffered(_ item: Item, mounted: Set<String>, now: Date = Date()) -> Bool {
        if isMounted(item.url, mounted) { return false }
        if item.kind == .incomplete {
            return now.timeIntervalSince(item.modified) >= abandonedAfter
        }
        return true
    }

    /// Whether it arrives ticked. Abandoned downloads always; installers once
    /// they are a month old.
    static func isTickedByDefault(_ item: Item, now: Date = Date()) -> Bool {
        switch item.kind {
        case .incomplete: return true
        case .installer:  return now.timeIntervalSince(item.added) >= installerTickedAfter
        }
    }

    // MARK: - Mounted images

    /// The disk images that are attached right now, by the path of their file.
    ///
    /// From `hdiutil info -plist`, which is the only thing that knows: a
    /// mounted volume does not say which file it came from. 19 ms measured.
    static func mountedImages() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return mountedImages(fromPlist: data)
    }

    /// The paths out of `hdiutil info -plist`'s output, separated so the
    /// parse can be checked against output written down.
    static func mountedImages(fromPlist data: Data) -> Set<String> {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { ($0["image-path"] as? String).map(canonical) })
    }

    /// One spelling of a path, whichever way it arrived.
    ///
    /// Symlinks resolved, not merely standardised: `standardizedFileURL`
    /// *removes* `/private` from `/private/var/…` while a directory listing
    /// can hand the same file back with it, so one disk image compared
    /// unequal to itself and a mounted installer was offered.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isMounted(_ url: URL, _ mounted: Set<String>) -> Bool {
        let path = canonical(url.path)
        return mounted.contains { canonical($0) == path }
    }

    // MARK: - Finding them

    /// Installers and partial downloads at the top of `folder`. Blocking.
    static func find(in folder: URL, mounted: Set<String>, now: Date = Date()) -> [Item] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .addedToDirectoryDateKey,
                                      .contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }

        var found: [Item] = []
        for url in urls {
            guard let kind = kind(of: url),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // A `.download` is a bundle Safari writes into; its size is what
            // is inside it. Everything else here is a single file.
            let bytes: Int64
            let modified: Date
            if values.isDirectory == true {
                guard let measured = AppLeftovers.measure(url, fm: .default) else { continue }
                bytes = measured
                modified = newestModification(in: url)
            } else {
                bytes = Int64(values.totalFileAllocatedSize ?? 0)
                modified = values.contentModificationDate ?? now
            }
            let item = Item(url: url, kind: kind, bytes: bytes,
                            added: values.addedToDirectoryDate ?? modified, modified: modified)
            if isOffered(item, mounted: mounted, now: now) { found.append(item) }
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
    }

    /// Whether the file is still what the scan saw: there, still at the top
    /// of the folder, not mounted, not written to since. A partial download
    /// that has started arriving again is refused, and so is a file replaced
    /// by another of the same name.
    static func isUnchanged(_ item: Item, in folder: URL, mounted: Set<String>) -> Bool {
        guard canonical(item.url.deletingLastPathComponent().path) == canonical(folder.path),
              !isMounted(item.url, mounted) else { return false }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return false }
        return abs(newestModification(in: item.url).timeIntervalSince(item.modified)) < 1
    }

    /// The newest modification date of a file, or of anything inside a
    /// folder.
    ///
    /// A `.download` bundle's own date does not move while Safari writes the
    /// file inside it, so "untouched for a day" read off the bundle alone
    /// would call a download in progress abandoned. A fresh URL each time:
    /// Foundation caches resource values on a URL, and the check before the
    /// Bin must read the disk, not the scan's answer.
    static func newestModification(in url: URL) -> Date {
        let key: URLResourceKey = .contentModificationDateKey
        let fresh = URL(fileURLWithPath: url.path)
        var newest = (try? fresh.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
        if let walk = FileManager.default.enumerator(at: fresh, includingPropertiesForKeys: [key],
                                                     options: [], errorHandler: { _, _ in true }) {
            for case let child as URL in walk {
                if let date = (try? child.resourceValues(forKeys: [key]))?.contentModificationDate,
                   date > newest { newest = date }
            }
        }
        return newest
    }
}
