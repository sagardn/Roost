import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// What the clipboard code needs of a pasteboard.
///
/// A protocol so the capture and restore rules run against a pasteboard made
/// up in a test, instead of the one the developer is using: a test suite
/// that wrote to the general pasteboard would replace whatever somebody had
/// just copied, every time it ran.
protocol ClipboardPasteboard: AnyObject {
    /// Moves whenever anything writes. Reading it is not reading the
    /// content, so it is what the monitor polls.
    var changeCount: Int { get }
    /// The types on the first item, or nil when the pasteboard is empty.
    var typeNames: [String]? { get }
    func data(forType type: String) -> Data?
    func string(forType type: String) -> String?
    var fileURLs: [URL] { get }
    /// Replaces the contents. Returns the change count afterwards.
    @discardableResult
    func write(_ representations: [(type: String, data: Data)], fileURLs: [URL]) -> Int
}

extension NSPasteboard: ClipboardPasteboard {
    var typeNames: [String]? { pasteboardItems?.first?.types.map(\.rawValue) ?? types?.map(\.rawValue) }

    func data(forType type: String) -> Data? { data(forType: PasteboardType(type)) }

    func string(forType type: String) -> String? { string(forType: PasteboardType(type)) }

    var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func write(_ representations: [(type: String, data: Data)], fileURLs: [URL]) -> Int {
        clearContents()
        if !fileURLs.isEmpty {
            // File URLs as objects, so Finder and Mail receive the files and
            // not a line of text naming them.
            writeObjects(fileURLs as [NSURL])
            if let first = pasteboardItems?.first {
                for item in representations { first.setData(item.data, forType: PasteboardType(item.type)) }
            }
        } else {
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: PasteboardType(representation.type))
            }
            writeObjects([item])
        }
        return changeCount
    }
}

// MARK: - Reading

/// What a copy was, read off the pasteboard, before anything is stored.
struct ClipboardCapture {
    var kind: ClipboardEntry.Kind
    var text: String?
    var fileURLs: [URL] = []
    /// Binary forms to keep: the image, or the RTF and HTML of rich text.
    var payloads: [(type: String, data: Data)] = []
    var types: [String]
    var fingerprint: String

    /// Why a change was not captured. Said in the settings page's count of
    /// what was skipped; never logged with the content.
    enum Skip: Error, Equatable {
        case empty
        /// Roost's own restore coming back round.
        case ownRestore
        /// The app that wrote it marked it as not for keeping.
        case markedPrivate
        /// The user has that kind switched off.
        case kindOff
        case tooLarge
        case excludedApp
    }

    struct Options: Equatable {
        var captureText = true
        var captureImages = true
        var keepRichText = true
        /// The largest image kept, in bytes, as the pasteboard holds it.
        var maximumImageBytes = 25 * 1_048_576
        /// The largest text kept. Above it the copy is skipped, not cut: a
        /// truncated text restored would be a different text.
        var maximumTextBytes = 2 * 1_048_576
    }

    static func read(_ pasteboard: ClipboardPasteboard, options: Options) -> Result<ClipboardCapture, Skip> {
        guard let types = pasteboard.typeNames, !types.isEmpty else { return .failure(.empty) }
        if types.contains(ClipboardTypes.restoredMarker) { return .failure(.ownRestore) }
        if types.contains(where: ClipboardTypes.doNotKeep.contains) { return .failure(.markedPrivate) }

        let string = pasteboard.string(forType: ClipboardTypes.string)
        let hasString = !(string ?? "").isEmpty

        // Files first: Finder puts the file's icon on the pasteboard as an
        // image and its name as a string, and either alone would be the wrong
        // thing to keep.
        if types.contains(ClipboardTypes.fileURL) {
            guard options.captureText else { return .failure(.kindOff) }
            let urls = pasteboard.fileURLs
            guard !urls.isEmpty else { return .failure(.empty) }
            let paths = urls.map(\.path).joined(separator: "\n")
            return .success(ClipboardCapture(kind: .files, text: paths, fileURLs: urls, types: types,
                                             fingerprint: fingerprint("files", Data(paths.utf8))))
        }

        // Text wins where there is any. A spreadsheet's cells come with a
        // picture of the cells, and what somebody copying cells wants back
        // is the cells.
        if hasString, let string {
            guard options.captureText else { return .failure(.kindOff) }
            guard string.utf8.count <= options.maximumTextBytes else { return .failure(.tooLarge) }

            var payloads: [(type: String, data: Data)] = []
            if options.keepRichText {
                for type in [ClipboardTypes.rtf, ClipboardTypes.html] where types.contains(type) {
                    if let data = pasteboard.data(forType: type), data.count <= options.maximumTextBytes {
                        payloads.append((type, data))
                    }
                }
            }
            let kind: ClipboardEntry.Kind = isLink(string) ? .url
                : payloads.isEmpty ? .text : .richText
            var seed = Data(string.utf8)
            payloads.forEach { seed.append($0.data) }
            return .success(ClipboardCapture(kind: kind, text: string, payloads: payloads, types: types,
                                             fingerprint: fingerprint(kind.rawValue, seed)))
        }

        for type in [ClipboardTypes.png, ClipboardTypes.jpeg, ClipboardTypes.tiff] where types.contains(type) {
            guard options.captureImages else { return .failure(.kindOff) }
            // The size cannot be checked before the read, so an image past
            // the limit is fetched in full and then dropped: a 181 MB TIFF
            // took the resident set from 111 MB to 435 MB here. A pasteboard
            // hands over a type's bytes or nothing and has no way of being
            // asked how many there are; NSPasteboardItem does not carry a
            // size either. It is a spike rather than a leak -- three copies
            // in a row stayed at 435 MB and it drains back down.
            //
            // Wrapping this in an `autoreleasepool` looks like the fix and is
            // not: measured at 428 MB against 435, which is noise. The read
            // happens in a Timer callback, and the run loop already drains a
            // pool around each of those, so there was nothing left for a
            // second one to release. What does bound the damage is the order
            // of the types -- the compressed ones are tried first, so a
            // screenshot arrives as PNG at a few MB and its 181 MB TIFF form
            // is never asked for.
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= options.maximumImageBytes else { return .failure(.tooLarge) }
            return .success(ClipboardCapture(kind: .image, text: nil, payloads: [(type, data)], types: types,
                                             fingerprint: fingerprint("image", data)))
        }
        return .failure(.empty)
    }

    /// A single link and nothing else: one line, no spaces, a scheme the
    /// system can open. Text that merely contains a link is text.
    static func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return url.host != nil
        case "mailto", "ftp", "sftp", "ssh", "tel", "facetime", "file": return true
        default: return false
        }
    }

    static func fingerprint(_ kind: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Writing back

enum ClipboardRestore {

    enum Outcome: Equatable {
        case complete
        /// Some stored forms could not be read back -- a payload file gone
        /// missing -- so the plain text alone was restored.
        case partial(missing: [String])
        case failed
    }

    /// Puts an entry back on the pasteboard, with every form it was kept in.
    ///
    /// `payload` reads a stored form back by file name; nil for one that is
    /// gone. Returns what happened and the change count after the write, so
    /// the monitor can skip it.
    static func restore(_ entry: ClipboardEntry, to pasteboard: ClipboardPasteboard,
                        payload: (ClipboardEntry.Payload) -> Data?) -> (Outcome, Int) {
        var representations: [(type: String, data: Data)] = []
        var missing: [String] = []

        if let text = entry.text, entry.kind != .files {
            representations.append((ClipboardTypes.string, Data(text.utf8)))
        }
        if entry.kind == .url, let text = entry.text {
            representations.append((ClipboardTypes.url, Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
        }
        for stored in entry.payloads {
            if let data = payload(stored) {
                representations.append((stored.type, data))
                // TIFF is what older apps look for first; a PNG alone is
                // not pasted into some of them at all.
                if stored.type == ClipboardTypes.png || stored.type == ClipboardTypes.jpeg,
                   let tiff = ClipboardImages.tiff(from: data) {
                    representations.append((ClipboardTypes.tiff, tiff))
                }
            } else {
                missing.append(stored.type)
            }
        }
        let urls = (entry.fileURLs ?? []).compactMap(URL.init(string:))
        if entry.kind == .image, representations.isEmpty { return (.failed, pasteboard.changeCount) }
        if entry.kind == .files, urls.isEmpty { return (.failed, pasteboard.changeCount) }
        if representations.isEmpty, urls.isEmpty { return (.failed, pasteboard.changeCount) }

        representations.append((ClipboardTypes.restoredMarker, Data()))
        let count = pasteboard.write(representations, fileURLs: urls)
        return (missing.isEmpty ? .complete : .partial(missing: missing), count)
    }
}

// MARK: - Images

/// Image work, through ImageIO: it decodes only as much as it is asked for,
/// so a thumbnail of a 40-megapixel screenshot never decodes 40 megapixels.
enum ClipboardImages {

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// A PNG no larger than `side` pixels on its long edge.
    static func thumbnail(_ data: Data, side: Int = 240) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side
              ] as CFDictionary) else { return nil }
        return encode(image, as: UTType.png)
    }

    /// TIFF as PNG, for storage. A screenshot copied as TIFF is often four
    /// times the size of the same pixels as PNG, losslessly.
    static func png(fromTIFF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image, as: UTType.png)
    }

    static func tiff(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image, as: UTType.tiff)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
