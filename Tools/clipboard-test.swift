//
//  clipboard-test.swift
//
//  Exercises clipboard history: what a copy is captured as, what is skipped,
//  how the history deduplicates, limits, expires, pins, searches and
//  filters, how the store survives a restart, a corrupt index and stray
//  files, and how a restore puts an entry back.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Settings/Preferences.swift \
//            Roost/Clipboard/ClipboardEntry.swift \
//            Roost/Clipboard/ClipboardHistory.swift \
//            Roost/Clipboard/ClipboardPasteboard.swift \
//            Roost/Clipboard/ClipboardStore.swift \
//            Roost/Clipboard/ClipboardSettings.swift \
//            Roost/Clipboard/ClipboardService.swift \
//            Tools/clipboard-test.swift | swift -
//
//  Every pasteboard here is `FakePasteboard`. A suite that used the general
//  pasteboard would replace whatever the person running it had just copied,
//  and the store writes only into a temporary directory it deletes.
//
import AppKit

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

final class FakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var items: [String: Data] = [:]
    var urls: [URL] = []

    var typeNames: [String]? { items.isEmpty && urls.isEmpty ? nil
        : Array(items.keys) + (urls.isEmpty ? [] : [ClipboardTypes.fileURL]) }
    func data(forType type: String) -> Data? { items[type] }
    func string(forType type: String) -> String? { items[type].flatMap { String(data: $0, encoding: .utf8) } }
    var fileURLs: [URL] { urls }

    func write(_ representations: [(type: String, data: Data)], fileURLs: [URL]) -> Int {
        items = [:]
        for item in representations { items[item.type] = item.data }
        urls = fileURLs
        changeCount += 1
        return changeCount
    }

    /// What another app copying would do.
    func copy(_ values: [String: Data], files: [URL] = []) {
        items = values
        urls = files
        changeCount += 1
    }
}

func text(_ string: String) -> [String: Data] { [ClipboardTypes.string: Data(string.utf8)] }

/// A real PNG of the given size, drawn here so no fixture file is needed.
func png(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func capture(_ board: FakePasteboard, _ options: ClipboardCapture.Options = .init()) -> ClipboardCapture? {
    if case .success(let made) = ClipboardCapture.read(board, options: options) { return made }
    return nil
}

func skip(_ board: FakePasteboard, _ options: ClipboardCapture.Options = .init()) -> ClipboardCapture.Skip? {
    if case .failure(let reason) = ClipboardCapture.read(board, options: options) { return reason }
    return nil
}

func entry(_ text: String, at date: Date, pinned: Bool = false, kind: ClipboardEntry.Kind = .text) -> ClipboardEntry {
    ClipboardEntry(id: UUID(), kind: kind, date: date, text: text, fileURLs: nil, payloads: [],
                   pixelWidth: nil, pixelHeight: nil, thumbnail: nil, isPinned: pinned,
                   sourceBundleID: nil, sourceName: nil, types: [ClipboardTypes.string],
                   byteSize: text.utf8.count,
                   fingerprint: ClipboardCapture.fingerprint(kind.rawValue, Data(text.utf8)))
}

// MARK: - Capture

print("Capture")

let board = FakePasteboard()
check("an empty pasteboard captures nothing", skip(board) == .empty)

board.copy(text("hello world"))
check("plain text is captured as text", capture(board)?.kind == .text && capture(board)?.text == "hello world")

board.copy(text("https://example.com/path?q=1"))
check("a lone link is a URL", capture(board)?.kind == .url)
board.copy(text("see https://example.com for details"))
check("text that contains a link is text", capture(board)?.kind == .text)
board.copy(text("javascript:alert(1)"))
check("a scheme nobody opens is not a link", capture(board)?.kind == .text)

var rich = text("bold")
rich[ClipboardTypes.rtf] = Data(#"{\rtf1\ansi {\b bold}}"#.utf8)
board.copy(rich)
check("text with RTF is rich text", capture(board)?.kind == .richText)
check("and keeps the RTF", capture(board)?.payloads.map(\.type) == [ClipboardTypes.rtf])
var plainOnly = ClipboardCapture.Options()
plainOnly.keepRichText = false
check("rich text kept off is plain text", capture(board, plainOnly)?.kind == .text
      && capture(board, plainOnly)?.payloads.isEmpty == true)

let picture = png(width: 400, height: 300)
board.copy([ClipboardTypes.png: picture])
check("an image is captured as an image", capture(board)?.kind == .image)
var noImages = ClipboardCapture.Options()
noImages.captureImages = false
check("images switched off are skipped", skip(board, noImages) == .kindOff)
var small = ClipboardCapture.Options()
small.maximumImageBytes = picture.count - 1
check("an image over the size limit is skipped, not shrunk", skip(board, small) == .tooLarge)

var cells = text("A1\tB1")
cells[ClipboardTypes.tiff] = picture
board.copy(cells)
check("text beside a picture of it is kept as the text", capture(board)?.kind == .text)

var noText = ClipboardCapture.Options()
noText.captureText = false
board.copy(text("secret-ish"))
check("text switched off is skipped", skip(board, noText) == .kindOff)
var tiny = ClipboardCapture.Options()
tiny.maximumTextBytes = 4
check("text over its limit is skipped, not cut", skip(board, tiny) == .tooLarge)

board.copy([ClipboardTypes.string: Data("hunter2".utf8), "org.nspasteboard.ConcealedType": Data()])
check("a concealed copy is never captured", skip(board) == .markedPrivate)
board.copy([ClipboardTypes.string: Data("x".utf8), "org.nspasteboard.TransientType": Data()])
check("a transient copy is never captured", skip(board) == .markedPrivate)
board.copy([ClipboardTypes.string: Data("x".utf8), "com.agilebits.onepassword": Data()])
check("1Password's own marker is respected", skip(board) == .markedPrivate)

let file = URL(fileURLWithPath: "/tmp/report.pdf")
board.copy([ClipboardTypes.tiff: picture, ClipboardTypes.string: Data("report.pdf".utf8)], files: [file])
check("a copied file is a files entry, not its icon or its name", capture(board)?.kind == .files)
check("and keeps the URL", capture(board)?.fileURLs == [file])

board.copy(text("same"))
let first = capture(board)!.fingerprint
board.copy(text("same"))
check("the same text twice has the same fingerprint", capture(board)!.fingerprint == first)
board.copy(text("Same"))
check("different text has a different one", capture(board)!.fingerprint != first)

// MARK: - Restore and the loop it must not start

print("\nRestore")

let restored = entry("put me back", at: Date())
let (outcome, count) = ClipboardRestore.restore(restored, to: board) { _ in nil }
check("a text entry restores completely", outcome == .complete)
check("the change count it reports is the pasteboard's", count == board.changeCount)
check("the text is on the pasteboard", board.string(forType: ClipboardTypes.string) == "put me back")
check("marked as Roost's own", board.items[ClipboardTypes.restoredMarker] != nil)
check("so reading it back captures nothing", skip(board) == .ownRestore)

var richEntry = entry("bold", at: Date(), kind: .richText)
richEntry.payloads = [.init(type: ClipboardTypes.rtf, file: "a.rtf", bytes: 3)]
let rtf = Data(#"{\rtf1 {\b bold}}"#.utf8)
check("rich text restores its RTF", ClipboardRestore.restore(richEntry, to: board) { _ in rtf }.0 == .complete
      && board.items[ClipboardTypes.rtf] == rtf
      && board.string(forType: ClipboardTypes.string) == "bold")
check("a missing RTF file is reported, and the text still goes back",
      ClipboardRestore.restore(richEntry, to: board) { _ in nil }.0 == .partial(missing: [ClipboardTypes.rtf])
      && board.string(forType: ClipboardTypes.string) == "bold")

var imageEntry = entry("", at: Date(), kind: .image)
imageEntry.text = nil
imageEntry.payloads = [.init(type: ClipboardTypes.png, file: "a.png", bytes: picture.count)]
let before = board.changeCount
check("an image whose file is gone fails rather than restoring nothing",
      ClipboardRestore.restore(imageEntry, to: board) { _ in nil }.0 == .failed)
check("and leaves the pasteboard alone", board.changeCount == before)
check("an image restores as PNG and TIFF",
      ClipboardRestore.restore(imageEntry, to: board) { _ in picture }.0 == .complete
      && board.items[ClipboardTypes.png] == picture && board.items[ClipboardTypes.tiff] != nil)

var link = entry("https://example.com", at: Date(), kind: .url)
link.text = "https://example.com"
_ = ClipboardRestore.restore(link, to: board) { _ in nil }
check("a URL restores as a URL as well as text", board.items[ClipboardTypes.url] != nil)

// MARK: - History

print("\nHistory")

let now = Date()
var history = ClipboardHistory()
history.add(entry("one", at: now.addingTimeInterval(-30)))
history.add(entry("two", at: now.addingTimeInterval(-20)))
check("newest first", history.entries.map(\.text) == ["two", "one"])
let duplicate = history.add(entry("two", at: now))
check("the same copy twice in a row is one entry", history.entries.count == 2 && duplicate != nil)
check("and it moves to now", history.entries.first?.date == now)
history.add(entry("one", at: now.addingTimeInterval(1)))
check("an older copy made again moves to the top instead of repeating",
      history.entries.map(\.text) == ["one", "two"])

var pinned = ClipboardHistory()
for index in 0..<10 { pinned.add(entry("item \(index)", at: now.addingTimeInterval(Double(index)))) }
let keep = pinned.entries.last!.id
pinned.setPinned(keep, true)
let dropped = pinned.enforce(.init(maximumEntries: 3, retention: nil))
check("the limit keeps the newest unpinned", pinned.entries.filter { !$0.isPinned }.map(\.text)
      == ["item 9", "item 8", "item 7"])
check("a pin survives the limit", pinned.entry(keep) != nil)
check("and the dropped entries are handed back for their files", dropped.count == 6)

var aging = ClipboardHistory()
aging.add(entry("old", at: now.addingTimeInterval(-90_000)))
aging.add(entry("old pinned", at: now.addingTimeInterval(-90_000), pinned: true))
aging.add(entry("new", at: now))
aging.enforce(.init(maximumEntries: 100, retention: 86_400), now: now)
check("retention removes the old", aging.entries.map(\.text) == ["new", "old pinned"])
var agingAll = ClipboardHistory()
agingAll.add(entry("old pinned", at: now.addingTimeInterval(-90_000), pinned: true))
agingAll.enforce(.init(maximumEntries: 100, retention: 86_400, retentionIncludesPinned: true), now: now)
check("pins expire only when that was chosen", agingAll.entries.isEmpty)

var searchable = ClipboardHistory()
searchable.add(entry("Café menu for Friday", at: now))
searchable.add(entry("https://roost.app", at: now.addingTimeInterval(1), kind: .url))
var photo = entry("", at: now.addingTimeInterval(2), kind: .image)
photo.text = nil
photo.pixelWidth = 1920
photo.pixelHeight = 1080
photo.sourceName = "Preview"
searchable.add(photo)
searchable.setPinned(searchable.entries.last!.id, true)
check("search ignores case and accents", searchable.matching("cafe", filter: .all).count == 1)
check("every word must match, in any order", searchable.matching("friday menu", filter: .all).count == 1
      && searchable.matching("friday lunch", filter: .all).isEmpty)
check("an image is found by its source app", searchable.matching("preview", filter: .all).first?.kind == .image)
check("and by its size", searchable.matching("1920", filter: .all).count == 1)
check("the text filter leaves out images", searchable.matching("", filter: .text).count == 2)
check("the image filter is only images", searchable.matching("", filter: .images).map(\.kind) == [.image])
check("the pinned filter is only pins", searchable.matching("", filter: .pinned).map(\.text) == ["Café menu for Friday"])

var clearing = searchable
let cleared = clearing.clear(keepingPinned: true)
check("clearing unpinned keeps pins", clearing.entries.count == 1 && cleared.count == 2)
check("clearing all keeps nothing", { var all = searchable; all.clear(keepingPinned: false); return all.entries.isEmpty }())
check("deleting one removes only it", { var one = searchable; one.remove(photo.id); return one.entries.count == 2 }())

check("a preview is the first non-blank line", ClipboardPreview.line("\n\n  first line \nsecond") == "first line")
check("a long preview is cut with an ellipsis", ClipboardPreview.line(String(repeating: "a", count: 500), limit: 10)
      == "aaaaaaaaaa…")
check("extra lines are counted", ClipboardPreview.extraLines("a\nb\nc") == 2)

// MARK: - Store

print("\nStore")

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("roost-clipboard-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

let store = ClipboardStore(directory: root, persistent: true)
check("a new store opens empty", store.open().isEmpty)

board.copy([ClipboardTypes.tiff: ClipboardImages.tiff(from: picture)!])
let tiffCapture = capture(board)!
let stored = try! store.makeEntry(from: tiffCapture, date: now, sourceBundleID: "com.apple.Preview",
                                  sourceName: "Preview")
check("a TIFF is kept as PNG", stored.payloads.map(\.type) == [ClipboardTypes.png])
check("its size is recorded", stored.pixelWidth == 400 && stored.pixelHeight == 300)
check("it has a thumbnail", stored.thumbnail != nil)
let thumbSize = stored.thumbnail.flatMap { try? Data(contentsOf: store.url(ofFile: $0)) }
    .flatMap(ClipboardImages.pixelSize)
check("no larger than 240 on its long edge", thumbSize.map { max($0.0, $0.1) <= 240 } == true)
let attributes = try? FileManager.default.attributesOfItem(atPath: store.url(ofFile: stored.payloads[0].file).path)
check("payload files are readable by the owner only",
      (attributes?[.posixPermissions] as? Int) == 0o600)
let folder = try? FileManager.default.attributesOfItem(atPath: root.path)
check("and the folder is the owner's only", (folder?[.posixPermissions] as? Int) == 0o700)

let words = entry("persisted", at: now)
try! store.save([stored, words])
let reopened = ClipboardStore(directory: root, persistent: true).open()
check("entries survive a restart", reopened.map(\.id) == [stored.id, words.id])
check("an image's payload is still readable", store.data(reopened[0].payloads[0]) != nil)

try! Data("stray".utf8).write(to: root.appendingPathComponent("payloads/stray.png"))
check("a file no entry names is removed on open",
      ClipboardStore(directory: root, persistent: true).open().count == 2
      && !FileManager.default.fileExists(atPath: root.appendingPathComponent("payloads/stray.png").path))

store.delete([stored])
check("deleting an entry deletes its payload and thumbnail",
      stored.files.allSatisfy { !FileManager.default.fileExists(atPath: store.url(ofFile: $0).path) })

try! Data("{ not json".utf8).write(to: root.appendingPathComponent("index.json"))
let corrupt = ClipboardStore(directory: root, persistent: true)
check("a corrupt index opens empty rather than failing", corrupt.open().isEmpty)
check("and says so", corrupt.problem != nil)
check("and is kept, set aside",
      ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        .contains { $0.hasPrefix("index-unreadable-") })

let session = root.appendingPathComponent("session")
let temporary = ClipboardStore(directory: session, persistent: false)
_ = temporary.open()
try! temporary.save([words])
check("a session-only store forgets on the next open",
      ClipboardStore(directory: session, persistent: false).open().isEmpty)
temporary.close()
check("and removes its files when it closes", !FileManager.default.fileExists(atPath: session.path))

// MARK: - The service

print("\nService")

/// A service on a fake pasteboard and a temporary store, with its work run
/// at once instead of on queues, so each check sees the result of the last.
func service(_ options: ClipboardOptions, board: FakePasteboard,
             directory: URL, front: String? = "com.example.editor") -> ClipboardService {
    var current = options
    let made = ClipboardService(pasteboard: board,
                                store: ClipboardStore(directory: directory, persistent: true),
                                options: { current },
                                frontmost: { (front, front.map { _ in "Editor" }) })
    made.background = { $0() }
    made.foreground = { $0() }
    made.accessDenied = { false }
    _ = current
    return made
}

let on = ClipboardOptions(monitoring: true, capture: .init(),
                          limits: .init(maximumEntries: 200, retention: nil),
                          persistent: true, excludedApps: ["com.example.passwords"])
var off = on
off.monitoring = false

let serviceRoot = root.appendingPathComponent("service")
let pad = FakePasteboard()
pad.copy(text("copied before Roost was watching"))

let watcher = service(on, board: pad, directory: serviceRoot)
watcher.start()
check("the service loads and watches when monitoring is on", watcher.isLoaded && watcher.isWatching)
watcher.check()
check("what was on the clipboard before is not captured", watcher.history.entries.isEmpty)

pad.copy(text("first copy"))
watcher.check()
check("a new copy is captured", watcher.history.entries.first?.text == "first copy")
watcher.check()
check("an unchanged clipboard is not read again", watcher.history.entries.count == 1)

pad.copy(text("second copy"))
watcher.check()
let firstID = watcher.history.entries.first { $0.text == "first copy" }!.id
check("restoring an entry succeeds", watcher.restore(firstID) == .complete)
check("and puts it on the clipboard", pad.string(forType: ClipboardTypes.string) == "first copy")
watcher.check()
check("restoring does not capture it again", watcher.history.entries.count == 2)
check("it moves to the top as the most recently used",
      watcher.history.entries.first?.id == firstID)

pad.copy([ClipboardTypes.string: Data("x".utf8), ClipboardTypes.restoredMarker: Data()])
watcher.check()
check("anything carrying Roost's marker is skipped even with a new count",
      watcher.history.entries.count == 2)

pad.copy(text("first copy"))
watcher.check()
check("copying the same thing again makes no second entry", watcher.history.entries.count == 2)

let excluded = service(on, board: pad, directory: root.appendingPathComponent("excluded"),
                       front: "com.example.passwords")
excluded.start()
pad.copy(text("from an excluded app"))
excluded.check()
check("a copy made while an excluded app is in front is not kept", excluded.history.entries.isEmpty)
check("and is counted as skipped", excluded.skipped[.excludedApp] == 1)

let paused = service(off, board: pad, directory: root.appendingPathComponent("off"))
paused.start()
check("with monitoring off there is no timer", !paused.isWatching && paused.status == .off)
pad.copy(text("while off"))
paused.check()
check("and nothing is captured", paused.history.entries.isEmpty)

let blocked = service(on, board: pad, directory: root.appendingPathComponent("blocked"))
blocked.accessDenied = { true }
blocked.start()
check("macOS refusing access reads as blocked", blocked.status == .blocked)
pad.copy(text("while blocked"))
blocked.check()
check("and nothing is read", blocked.history.entries.isEmpty)

pad.copy([ClipboardTypes.png: picture])
watcher.check()
let image = watcher.history.entries.first!
check("an image copy is kept as an image", image.kind == .image)
let imageFiles = image.files.map { serviceRoot.appendingPathComponent("payloads/\($0)") }
check("with its files on disk", imageFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
watcher.delete(image.id)
check("deleting it deletes them", imageFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

let reloaded = service(on, board: pad, directory: serviceRoot)
reloaded.start()
check("history survives a restart", reloaded.history.entries.map(\.text) == watcher.history.entries.map(\.text))

watcher.setPinned(firstID, true)
watcher.clear(keepingPinned: true)
check("clearing unpinned keeps the pin", watcher.history.entries.map(\.id) == [firstID])

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
