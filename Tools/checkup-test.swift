//
//  checkup-test.swift
//
//  Exercises the Check-up's own rules: how the finders' results become one
//  list, when a report is reused, and what happens at the Bin.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Palette.swift \
//            Roost/Monitor/Readings.swift Roost/Monitor/DiskReadings.swift \
//            Roost/Monitor/MemoryReadings.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift Roost/Cleanup/AIAssistants.swift \
//            Roost/System/BackgroundItems.swift Roost/Cleanup/OrphanedData.swift \
//            Roost/Cleanup/StaleDownloads.swift Roost/Cleanup/Duplicates.swift \
//            Roost/System/Protection.swift Roost/System/Recommendations.swift \
//            Roost/Cleanup/CheckUp.swift Tools/checkup-test.swift | swift -
//
//  Each finder has its own suite. This one is about the seams: the same file
//  found twice, a report shown after the disk has changed, and a file that
//  changed between the scan and the button. The Bin is a scratch folder here
//  -- `moveToBin` takes the move as a function so these cases can run without
//  filling the developer's real one.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent("checkup-test-\(UUID().uuidString)")
let bin = fm.temporaryDirectory.appendingPathComponent("checkup-bin-\(UUID().uuidString)")
try? fm.createDirectory(at: bin, withIntermediateDirectories: true)

@discardableResult
func make(_ path: String, bytes: Int = 50_000, modified: Date? = nil) -> URL {
    let url = home.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data(repeating: 3, count: bytes))
    if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    return url
}

let now = Date()
let day: TimeInterval = 86_400
let old = now.addingTimeInterval(-200 * day)

// Leftovers of a removed app, one of which an AI finder also reaches.
make("Library/Caches/com.gone.app/blob", bytes: 400_000)
make("Library/Application Support/com.gone.app/state.json")
make("Library/Caches/com.anthropic.claudefordesktop/blob", bytes: 90_000, modified: old)
try? fm.setAttributes([.modificationDate: old],
                      ofItemAtPath: home.appendingPathComponent("Library/Caches/com.anthropic.claudefordesktop").path)
// Downloads.
make("Downloads/Old.dmg", bytes: 300_000, modified: old)
make("Downloads/clip.mp4.crdownload", bytes: 20_000, modified: old)

let known: Set<String> = ["com.maker.thing"]
var context = CheckUp.Context()
context.home = home
context.known = known

let leftovers = OrphanedData.find(home: home, known: known, lookup: { _ in false })
let downloads = StaleDownloads.find(in: context.downloads, mounted: [], now: now)
let cacheURL = home.appendingPathComponent("Library/Caches/com.anthropic.claudefordesktop")
let conversations = AIAssistants.Item(url: home.appendingPathComponent(".claude/projects"),
                                      kind: .conversations, bytes: 700_000, lastUsed: old)
let models = AIAssistants.Item(url: home.appendingPathComponent(".ollama/models"),
                               kind: .models, bytes: 9_000_000, lastUsed: old)
let aiCache = AIAssistants.Item(url: cacheURL, kind: .caches, bytes: 90_000, lastUsed: old)

print("One list")
check("the orphan finder also reaches the AI app's cache (the overlap is real)",
      leftovers.contains { $0.url == cacheURL })
let merged = CheckUp.entries(leftovers: leftovers, downloads: downloads,
                             assistants: [aiCache, conversations, models], known: known, now: now)
let urls = merged.entries.map(\.url)
check("a folder two finders reach is listed once", urls.filter { $0 == cacheURL }.count == 1)
check("and under the finder that knows what it is",
      merged.entries.first { $0.url == cacheURL }?.section == .assistants)
check("conversations are not listed", !urls.contains(conversations.url))
check("models are not listed", !urls.contains(models.url))
check("but what they hold is counted", merged.heldBack == 9_700_000)
check("sections in order", merged.entries.map(\.section.rawValue) == merged.entries.map(\.section.rawValue).sorted())
let leftoverRows = merged.entries.filter { $0.section == .leftovers }
check("biggest first within a section",
      zip(leftoverRows, leftoverRows.dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
func entry(_ path: String) -> CheckUp.Entry? {
    merged.entries.first { $0.url.path.hasSuffix(path) }
}
check("an orphan's cache is ticked", entry("Caches/com.gone.app")?.isTickedByDefault == true)
check("its app data is not", entry("Application Support/com.gone.app")?.isTickedByDefault == false)
// Built a long time ago but arrived in Downloads moments ago: not ticked,
// because ticking is by when it arrived (macOS's added date, which a test
// cannot backdate -- the downloads suite covers the month-old case).
check("an installer that only just arrived is not ticked, however old the file",
      entry("Old.dmg")?.isTickedByDefault == false)
check("an abandoned download is ticked", entry("clip.mp4.crdownload")?.isTickedByDefault == true)
check("an AI cache is ticked", entry("com.anthropic.claudefordesktop")?.isTickedByDefault == true)

// Found in review: a removed ChatGPT's support folder holds its saved
// sessions, which are held back -- and the orphan finder offered the folder.
let chat = make("Library/Application Support/com.openai.gone/sessions/s1", bytes: 30_000)
    .deletingLastPathComponent()
let chatFolder = chat.deletingLastPathComponent()
let chatCache = make("Library/Application Support/com.openai.gone/Code Cache/x", bytes: 20_000)
    .deletingLastPathComponent()
let nested = CheckUp.entries(
    leftovers: OrphanedData.find(home: home, known: known, lookup: { _ in false }),
    downloads: [],
    assistants: [AIAssistants.Item(url: chat, kind: .conversations, bytes: 30_000, lastUsed: old),
                 AIAssistants.Item(url: chatCache, kind: .caches, bytes: 20_000, lastUsed: old)],
    known: known, now: now)
check("a leftover that holds held-back conversations is not offered",
      !nested.entries.contains { $0.url == chatFolder })
check("the cache inside it is offered once, by the AI finder",
      nested.entries.filter { $0.url == chatCache }.count == 1)

// Found in a later review: the same folder, but with a conversation saved
// this week. The age rule hid it from the AI list, and the guard was built
// from that list -- so the folder holding it was offered again.
let recentNested = CheckUp.entries(
    leftovers: OrphanedData.find(home: home, known: known, lookup: { _ in false }),
    downloads: [],
    assistants: [AIAssistants.Item(url: chat, kind: .conversations, bytes: 30_000, lastUsed: now),
                 AIAssistants.Item(url: chatCache, kind: .caches, bytes: 20_000, lastUsed: now)],
    assistantDays: 90, known: known, now: now)
check("a leftover holding a recent conversation is not offered",
      !recentNested.entries.contains { $0.url == chatFolder })
check("a cache the age rule holds back is not offered as a leftover instead",
      !recentNested.entries.contains { $0.url == chatCache })
check("and the recent conversation is still counted as held back",
      recentNested.heldBack == 30_000)
try? fm.removeItem(at: chatFolder)

print("Reusing a report")
var report = CheckUp.Report(finished: now.addingTimeInterval(-60))
check("a minute-old report is fresh", CheckUp.isFresh(report, lastMove: nil, now: now))
check("no report is not", !CheckUp.isFresh(nil, lastMove: nil, now: now))
check("an hour-old one is not",
      !CheckUp.isFresh(CheckUp.Report(finished: now.addingTimeInterval(-3600)), lastMove: nil, now: now))
check("one made before something was moved to the Bin is not",
      !CheckUp.isFresh(report, lastMove: now.addingTimeInterval(-30), now: now))
check("one made after is",
      CheckUp.isFresh(report, lastMove: now.addingTimeInterval(-90), now: now))
var listed = CheckUp.Report(finished: now.addingTimeInterval(-60))
listed.entries = merged.entries
check("a report whose rows are all still there is fresh",
      CheckUp.isFresh(listed, lastMove: nil, now: now, exists: { _ in true }))
// Another window -- Large files, the uninstaller -- moved one of them.
check("one listing a file moved elsewhere since is not",
      !CheckUp.isFresh(listed, lastMove: nil, now: now, exists: { $0 != merged.entries[0].url }))
report.isComplete = false
check("a stopped scan is never reused", !CheckUp.isFresh(report, lastMove: nil, now: now))

print("Advice")
var empty = CheckUp.Report(finished: now)
let inputs = empty.inputs
check("a stage that did not run says nothing about duplicates", inputs.duplicateBytes == nil)
check("or about protections", inputs.protection == nil)
check("or about background jobs", inputs.jobsMissingProgram == nil && inputs.jobsUnsigned == nil)
empty.entries = merged.entries
check("what is ticked and what is not are told apart",
      empty.inputs.cleanupTicked == empty.tickedBytes && empty.tickedBytes > 0 && empty.reviewBytes > 0)

print("At the Bin")
var moves: [URL] = []
func scratchTrash(_ url: URL) throws -> URL? {
    let landed = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    try fm.moveItem(at: url, to: landed)
    moves.append(url)
    return landed
}
var log: [String] = []
// What arrived ticked, plus the installer, ticked by hand.
let chosen = merged.entries.filter { $0.isTickedByDefault || $0.url.lastPathComponent == "Old.dmg" }
// Between the scan and the button: the app comes back, and a download resumes.
var later = context
later.known.insert("com.gone.app")
try? fm.setAttributes([.modificationDate: now], ofItemAtPath: home.appendingPathComponent("Downloads/clip.mp4.crdownload").path)
let outcome = CheckUp.moveToBin(chosen, in: later, trash: scratchTrash, log: { log.append($0) })
check("a reinstalled app's cache is refused", outcome.refused.contains { $0.path.hasSuffix("Caches/com.gone.app") })
check("a resumed download is refused", outcome.refused.contains { $0.lastPathComponent == "clip.mp4.crdownload" })
check("what was refused is still where it was",
      fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.gone.app").path))
check("the old installer went", outcome.moved.contains { $0.url.lastPathComponent == "Old.dmg" })
check("so did the AI cache", outcome.moved.contains { $0.url == cacheURL })
check("nothing unticked was touched",
      fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/com.gone.app").path))
check("only what passed the check reached the Bin", moves.count == outcome.moved.count)
check("each move is measured as it goes, not as the scan saw it",
      outcome.moved.first { $0.url.lastPathComponent == "Old.dmg" }.map { $0.bytes >= 300_000 } == true)
check("every move and every refusal is logged", log.count == chosen.count)
check("the log says where each went", log.contains { $0.contains(bin.path) })

print("When the move fails")
make("Downloads/Locked.pkg", bytes: 10_000, modified: old)
let lockedItem = StaleDownloads.find(in: context.downloads, mounted: [], now: now)
    .first { $0.name == "Locked.pkg" }!
struct Refusal: LocalizedError { var errorDescription: String? { "The file is locked." } }
let failed = CheckUp.moveToBin([CheckUp.Entry(source: .download(lockedItem), isTickedByDefault: true)],
                               in: context, trash: { _ in throw Refusal() })
check("a failed move is reported, not counted as moved", failed.moved.isEmpty && failed.failed.count == 1)
check("with macOS's reason", failed.failed.first?.reason == "The file is locked.")
check("and nothing is said to have been freed", failed.bytesMoved == 0)

print("The AI age rule")
var strict = context
strict.assistantDays = 30
make("Library/Caches/com.anthropic.claudefordesktop/fresh", bytes: 1000)   // written now
let usedToday = CheckUp.Entry(source: .assistant(AIAssistants.Item(
    url: home.appendingPathComponent("Library/Caches/com.anthropic.claudefordesktop"),
    kind: .caches, bytes: 1000, lastUsed: old)), isTickedByDefault: true)
check("a cache used since the scan is refused under the AI window's rule",
      !CheckUp.isStillOffered(usedToday, in: strict, now: now))

try? fm.removeItem(at: home)
try? fm.removeItem(at: bin)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
