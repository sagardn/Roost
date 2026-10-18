import Foundation

/// The history on disk.
///
/// `index.json` holds every entry's metadata and text; `payloads/` holds
/// one file per image, thumbnail, RTF and HTML form, named by a fresh UUID.
/// Kept in two because an index carrying images would be rewritten, images
/// and all, every time anything is copied.
///
/// Not thread-safe by itself and not meant to be: `ClipboardService` calls
/// it on one serial queue, so disk work never runs on the main thread and
/// never runs twice at once.
///
/// What is on disk is the user's alone: the directory is created 0700 and
/// every file 0600, inside their own Library. Nothing here is encrypted --
/// the protection is the account's own, and FileVault's where it is on --
/// and nothing in the interface says otherwise.
final class ClipboardStore {

    let directory: URL
    /// False keeps the history for this session only: the directory is
    /// emptied when the store opens and again when it closes. Changeable,
    /// so switching it off takes effect at the next quit without throwing
    /// away what is on screen now.
    var persistent: Bool

    private var payloads: URL { directory.appendingPathComponent("payloads", isDirectory: true) }
    private var index: URL { directory.appendingPathComponent("index.json") }
    private let files = FileManager.default

    /// Set when the index could not be read and was set aside.
    private(set) var problem: String?

    init(directory: URL, persistent: Bool) {
        self.directory = directory
        self.persistent = persistent
    }

    /// Where the app keeps it: beside the launcher's `apps.json`, in
    /// `~/Library/Application Support/Roost/`, which is where the manual
    /// says Roost keeps things. A build running under another bundle
    /// identifier -- a preview -- keeps its own, so it never reads or wipes
    /// the installed app's history.
    static var defaultDirectory: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.sagar.roost"
        let folder = id == "com.sagar.roost" ? "Roost" : "Roost (\(id))"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    // MARK: - Opening

    /// The entries on disk, after setting aside anything that cannot be read
    /// and deleting any file nothing names.
    func open() -> [ClipboardEntry] {
        if !persistent { wipe() }
        prepare()
        var entries: [ClipboardEntry] = []
        if files.fileExists(atPath: index.path) {
            do {
                entries = try JSONDecoder.clipboard.decode([ClipboardEntry].self, from: Data(contentsOf: index))
            } catch {
                // Kept, not deleted: it may be a few bytes from readable, and
                // it is somebody's history. The next save writes a new index.
                let aside = directory.appendingPathComponent("index-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? files.moveItem(at: index, to: aside)
                problem = localized("The saved clipboard history could not be read, so it was set aside as %0.", aside.lastPathComponent)
            }
        }
        removeOrphans(keeping: entries)
        return entries
    }

    /// Called at quit.
    func close() {
        if !persistent { wipe() }
    }

    private func prepare() {
        for folder in [directory, payloads] {
            try? files.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    private func wipe() {
        try? files.removeItem(at: directory)
    }

    /// Payload files no entry names: left by a crash between writing an
    /// image and saving the index that points at it, or by an index set
    /// aside.
    @discardableResult
    func removeOrphans(keeping entries: [ClipboardEntry]) -> Int {
        let named = Set(entries.flatMap(\.files))
        let present = (try? files.contentsOfDirectory(atPath: payloads.path)) ?? []
        var removed = 0
        for name in present where !named.contains(name) {
            if (try? files.removeItem(at: payloads.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Writing

    /// Turns a capture into an entry, writing its binary forms to disk.
    ///
    /// A TIFF image is kept as PNG -- the same pixels, losslessly, often a
    /// quarter of the size -- and every image gets a thumbnail, so a list of
    /// images never decodes a full-size one.
    func makeEntry(from capture: ClipboardCapture, date: Date,
                   sourceBundleID: String?, sourceName: String?) throws -> ClipboardEntry {
        prepare()
        var stored: [ClipboardEntry.Payload] = []
        var thumbnail: String?
        var size: (Int, Int)?
        var bytes = capture.text?.utf8.count ?? 0

        for payload in capture.payloads {
            var type = payload.type
            var data = payload.data
            if capture.kind == .image {
                if type == ClipboardTypes.tiff, let png = ClipboardImages.png(fromTIFF: data) {
                    type = ClipboardTypes.png
                    data = png
                }
                size = ClipboardImages.pixelSize(data)
                if let small = ClipboardImages.thumbnail(data) {
                    let name = UUID().uuidString + ".thumb.png"
                    try write(small, named: name)
                    thumbnail = name
                    bytes += small.count
                }
            }
            let name = UUID().uuidString + "." + Self.fileExtension(type)
            try write(data, named: name)
            stored.append(.init(type: type, file: name, bytes: data.count))
            bytes += data.count
        }

        return ClipboardEntry(id: UUID(), kind: capture.kind, date: date, text: capture.text,
                              fileURLs: capture.fileURLs.isEmpty ? nil : capture.fileURLs.map(\.absoluteString),
                              payloads: stored, pixelWidth: size?.0, pixelHeight: size?.1,
                              thumbnail: thumbnail, isPinned: false,
                              sourceBundleID: sourceBundleID, sourceName: sourceName,
                              types: capture.types, byteSize: bytes, fingerprint: capture.fingerprint)
    }

    func save(_ entries: [ClipboardEntry]) throws {
        prepare()
        let data = try JSONEncoder.clipboard.encode(entries)
        try data.write(to: index, options: [.atomic])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }

    /// Deletes everything an entry owns on disk.
    func delete(_ entries: [ClipboardEntry]) {
        for name in entries.flatMap(\.files) {
            try? files.removeItem(at: payloads.appendingPathComponent(name))
        }
    }

    // MARK: - Reading

    func data(_ payload: ClipboardEntry.Payload) -> Data? {
        try? Data(contentsOf: payloads.appendingPathComponent(payload.file))
    }

    func url(ofFile name: String) -> URL { payloads.appendingPathComponent(name) }

    // MARK: - Files

    private func write(_ data: Data, named name: String) throws {
        let url = payloads.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fileExtension(_ type: String) -> String {
        switch type {
        case ClipboardTypes.png:  return "png"
        case ClipboardTypes.jpeg: return "jpg"
        case ClipboardTypes.tiff: return "tiff"
        case ClipboardTypes.rtf:  return "rtf"
        case ClipboardTypes.html: return "html"
        default:                  return "data"
        }
    }
}

extension JSONEncoder {
    static var clipboard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var clipboard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
