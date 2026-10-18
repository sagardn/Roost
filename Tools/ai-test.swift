//
//  ai-test.swift
//
//  Exercises which of an AI assistant's files are offered for removal.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift \
//            Roost/Cleanup/AIAssistants.swift Tools/ai-test.swift | swift -
//
//  These directories hold two things that look alike from the outside: a
//  cache the tool rebuilds without noticing, and the credential that keeps
//  somebody signed in. The names below were taken from the real contents of
//  ~/.claude, ~/.codex, ~/.grok, ~/.gemini, ~/.copilot and ~/.opencode, and
//  most of the cases are about what must NOT be offered.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func kind(_ name: String) -> AIAssistants.Kind? { AIAssistants.kind(of: name) }

// MARK: - What must never be offered

print("Nothing that signs somebody out, or that they installed")

// The entry a denylist forgets. Being signed out of every assistant with no
// idea why is the worst outcome this file can produce.
for name in ["auth.json", ".credentials.json", "credentials.json"] {
    check("\(name) is not offered", kind(name) == nil)
}
for name in ["settings.json", "config.toml", "config.json", "hooks.json",
             "managed_config.lock", "models.json"] {
    check("\(name) is not offered", kind(name) == nil)
}
// Installed functionality, not leavings.
for name in ["plugins", "skills", "installed-plugins", "bin", "packages",
             "bundled", "vendor", "grove", "ide", "antigravity-ide"] {
    check("\(name) is not offered", kind(name) == nil)
}
// Somebody's own writing and the tool's own backups.
for name in ["CLAUDE.md", "README.md", "CHANGELOG.md", "backups",
             "settings.json.bak", "agent_id", "installation_id"] {
    check("\(name) is not offered", kind(name) == nil)
}

// MARK: - What is offered, and as what

print("\nCaches, logs and downloads — the tool rebuilds these")

check("cache", kind("cache") == .caches)
check("caches", kind("caches") == .caches)
check("paste-cache", kind("paste-cache") == .caches)
check("marketplace-cache", kind("marketplace-cache") == .caches)
check("models_cache.json", kind("models_cache.json") == .caches)
check("logs", kind("logs") == .logs)
check("telemetry", kind("telemetry") == .logs)
// The schema number comes off, so logs_2.sqlite is logs.
check("logs_2.sqlite", kind("logs_2.sqlite") == .logs)
// And the write-ahead log travels with the database rather than being left
// behind as an orphan beside a file that is gone.
check("logs_2.sqlite-wal", kind("logs_2.sqlite-wal") == .logs)
check("logs_2.sqlite-shm", kind("logs_2.sqlite-shm") == .logs)
check("downloads", kind("downloads") == .downloads)

print("\nConversations and memory — a real loss, so never ticked")

check("projects", kind("projects") == .conversations)
check("sessions", kind("sessions") == .conversations)
check("session-env", kind("session-env") == .conversations)
check("shell-snapshots", kind("shell-snapshots") == .conversations)
check("history.jsonl", kind("history.jsonl") == .conversations)
check("file-history", kind("file-history") == .conversations)
check("prompt-history.jsonl", kind("prompt-history.jsonl") == .conversations)
check("thread_history_1.sqlite", kind("thread_history_1.sqlite") == .conversations)
check("memories_1.sqlite", kind("memories_1.sqlite") == .conversations)
check("active_sessions.json", kind("active_sessions.json") == .conversations)
check("plans", kind("plans") == .conversations)
check("todos", kind("todos") == .conversations)

print("\nWhat is ticked when the list opens")

check("a cache is ticked", AIAssistants.Kind.caches.isTickedByDefault)
check("logs are ticked", AIAssistants.Kind.logs.isTickedByDefault)
check("downloaded updates are ticked", AIAssistants.Kind.downloads.isTickedByDefault)
// Somebody who resumes old sessions loses them. They are shown, named and
// left for a person to decide about.
check("conversations are not", !AIAssistants.Kind.conversations.isTickedByDefault)

// MARK: - Where it looks

print("\nWhere an assistant keeps things")

let home = URL(fileURLWithPath: "/Users/someone")
let roots = AIAssistants.roots(for: "claude", home: home).map { $0.path }
check("the dot directory", roots.contains("/Users/someone/.claude"))
check("the XDG config directory", roots.contains("/Users/someone/.config/claude"))
check("the XDG state directory", roots.contains("/Users/someone/.local/state/claude"))
check("the XDG cache directory", roots.contains("/Users/someone/.cache/claude"))
check("Application Support",
      roots.contains("/Users/someone/Library/Application Support/claude"))
check("Library caches", roots.contains("/Users/someone/Library/Caches/claude"))
check("nothing outside the home folder",
      roots.allSatisfy { $0.hasPrefix("/Users/someone/") })

// Everything under ~/.cache is a cache whatever the tool named the
// directories inside it, so those are taken whole rather than classified.
print("\nRoots that are a cache in their entirety")

func whole(_ path: String) -> Bool {
    AIAssistants.isWhollyCache(URL(fileURLWithPath: path), home: home)
}
check("~/.cache/opencode is taken whole", whole("/Users/someone/.cache/opencode"))
check("~/Library/Caches/claude too", whole("/Users/someone/Library/Caches/claude"))
check("~/Library/Logs/claude too", whole("/Users/someone/Library/Logs/claude"))
check("but ~/.claude is not", !whole("/Users/someone/.claude"))
check("nor ~/.config/claude", !whole("/Users/someone/.config/claude"))
// The prefix must be a whole path component: a directory called
// ~/.cachesomething is not inside ~/.cache.
check("a lookalike directory is not inside the cache",
      !whole("/Users/someone/.cachesomething"))

print("\nThe list of assistants")

check("the ones measured are known",
      ["claude", "codex", "grok", "gemini", "copilot", "opencode"]
          .allSatisfy(AIAssistants.known.contains))
check("and nothing that is not an assistant is",
      !AIAssistants.known.contains("ssh") && !AIAssistants.known.contains("config"))

// MARK: - Empty is not the same as unreadable

print("\nA size that could not be read")

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("roost-ai-test-\(getpid())")
let fm = FileManager.default
try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

let empty = scratch.appendingPathComponent("empty-cache")
try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
check("an empty folder measures zero, not unknown",
      AppLeftovers.measure(empty, fm: fm) == 0)

let holding = scratch.appendingPathComponent("holding")
try? fm.createDirectory(at: holding, withIntermediateDirectories: true)
try? Data(count: 4096).write(to: holding.appendingPathComponent("blob"))
check("a folder with something in it measures it",
      (AppLeftovers.measure(holding, fm: fm) ?? 0) > 0)

// The case the optional exists for. A folder nobody may open is not a
// small folder, and 0 B said it was.
let shut = scratch.appendingPathComponent("shut")
try? fm.createDirectory(at: shut, withIntermediateDirectories: true)
try? Data(count: 4096).write(to: shut.appendingPathComponent("blob"))
try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
if getuid() == 0 {
    print("  --   running as root, which can read it anyway; skipped")
} else {
    check("a folder that will not open measures as unknown",
          AppLeftovers.measure(shut, fm: fm) == nil)
    check("and that is not the same as zero",
          AppLeftovers.measure(shut, fm: fm) != 0)
}
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path)

check("a path that is not there measures as unknown",
      AppLeftovers.measure(scratch.appendingPathComponent("absent"), fm: fm) == nil)
// Callers that only need a number to add up still get one: a total is a sum
// and has nowhere to put "unknown".
check("the summing form counts the unknown as nothing",
      AppLeftovers.size(of: scratch.appendingPathComponent("absent"), fm: fm) == 0)

check("an item is measured unless it says otherwise",
      AppLeftovers.Item(url: empty, bytes: 0, confidence: .certain).isMeasured)
check("and an AI item too",
      AIAssistants.Item(url: empty, kind: .caches, bytes: 0).isMeasured)

try? fm.removeItem(at: scratch)

// MARK: - Age, models, app caches, and the check before the Bin

print("\nAge, models and app caches, on a real folder")

do {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("ai-age-\(UUID().uuidString)")
    let fake = sandbox.appendingPathComponent("home")
    defer { try? fm.removeItem(at: sandbox) }
    let old = Date().addingTimeInterval(-200 * 86_400)
    let recent = Date().addingTimeInterval(-2 * 86_400)

    func put(_ path: String, _ date: Date, root: URL = fake) {
        let url = root.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(repeating: 7, count: 4096).write(to: url)
        try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    put(".claude/cache/old.bin", old)
    put(".claude/projects/-Users-x-code-Roost/s.jsonl", old)
    put(".claude/projects/-Users-x-code-Roost/2664aea4-1653-479d-b59f-2b3fccde87ff.jsonl", recent)
    put(".claude/projects/-Users-x-code-Roost/memory/MEMORY.md", old)
    put(".codex/sessions/2026/07/01/rollout-a.jsonl", old)
    put(".codex/sessions/2026/10/09/rollout-b.jsonl", recent)
    put(".claude/logs/new.log", recent)
    put(".claude/auth.json", old)
    put("Library/Application Support/Claude/Code Cache/js/a", old)
    put("Library/Application Support/Claude/claude_desktop_config.json", old)
    put("Library/Caches/com.openai.chat/Cache.db", old)
    put(".cache/huggingface/hub/models--org--small/blobs/x", old)
    put(".cache/huggingface/hub/.locks/x", old)
    put(".ollama/models/blobs/sha256-1", old)
    put("outside.txt", old, root: sandbox)
    try! fm.createSymbolicLink(at: fake.appendingPathComponent(".claude/escape-cache"),
                               withDestinationURL: sandbox)
    // Creating files dates their folders today, which the age rule rightly
    // reads as use. Back-date every folder; the files keep their own dates.
    if let walk = fm.enumerator(at: fake, includingPropertiesForKeys: [.isDirectoryKey]) {
        for case let url as URL in walk
            where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
    }

    let tools = AIAssistants.find(home: fake)
    let items = tools.flatMap(\.items)
    func item(_ path: String) -> AIAssistants.Item? {
        let want = fake.appendingPathComponent(path).standardizedFileURL.path.lowercased()
        return items.first { $0.url.standardizedFileURL.path.lowercased() == want }
    }

    check("an Electron Code Cache is offered as a cache",
          item("Library/Application Support/Claude/Code Cache")?.kind == .caches)
    check("but not the desktop app's config beside it",
          item("Library/Application Support/Claude/claude_desktop_config.json") == nil)
    check("an app's own Caches folder, by bundle id, is offered whole",
          item("Library/Caches/com.openai.chat")?.kind == .caches)
    check("a Hugging Face model is offered, as a model",
          item(".cache/huggingface/hub/models--org--small")?.kind == .models)
    check("but not the hub's lock folder", item(".cache/huggingface/hub/.locks") == nil)
    check("Ollama's store is one entry", item(".ollama/models")?.kind == .models)
    check("models are never ticked", !AIAssistants.Kind.models.isTickedByDefault)
    check("conversations still never ticked", !AIAssistants.Kind.conversations.isTickedByDefault)
    check("a login is still never offered", item(".claude/auth.json") == nil)
    check("each item knows when it was last used",
          (item(".claude/cache")?.lastUsed ?? Date()) < Date().addingTimeInterval(-100 * 86_400))

    let at90 = AIAssistants.offered(tools, olderThan: 90).flatMap(\.items)
    check("at 90 days the old cache is offered",
          at90.contains { $0.url.lastPathComponent == "cache" })
    check("at 90 days the logs written two days ago are not",
          !at90.contains { $0.url.lastPathComponent == "logs" })
    check("with no age rule, they are",
          AIAssistants.offered(tools, olderThan: nil).flatMap(\.items).contains { $0.url.lastPathComponent == "logs" })
    check("a tool with nothing old enough drops out", AIAssistants.offered(tools, olderThan: 100_000).isEmpty)
    check("unknown age is never old enough",
          !AIAssistants.Item(url: fake, kind: .caches, bytes: 1).isOld(enough: 1))

    print("\nA conversation at a time")
    check("projects is not offered whole", item(".claude/projects") == nil)
    let oldSession = item(".claude/projects/-Users-x-code-Roost/s.jsonl")
    let newSession = item(".claude/projects/-Users-x-code-Roost/2664aea4-1653-479d-b59f-2b3fccde87ff.jsonl")
    check("each session is its own entry", oldSession != nil && newSession != nil)
    check("the old one is offered at 90 days, the new one is not",
          at90.contains { $0.url == oldSession?.url } && !at90.contains { $0.url == newSession?.url })
    check("a project's memory is never offered",
          item(".claude/projects/-Users-x-code-Roost/memory") == nil
            && !items.contains { $0.url.pathComponents.contains("memory") })
    check("a session reads by its project", newSession?.displayName == "Roost · 2664aea4")
    let oldDay = item(".codex/sessions/2026/07/01/rollout-a.jsonl")
    check("dated folders are walked down to the day's sessions",
          oldDay != nil && item(".codex/sessions/2026") == nil)
    check("and named by their day", oldDay?.displayName == "2026-07-01 · rollout-a.jsonl")
    check("July's session is old enough, October's is not",
          at90.contains { $0.url == oldDay?.url }
            && !at90.contains { $0.url.lastPathComponent == "rollout-b.jsonl" })

    print("\nChecked again before the Bin")
    let session = oldSession!
    put(".claude/projects/-Users-x-code-Roost/s.jsonl", Date())   // written to after the scan
    let busy = AIAssistants.moveToBin([session], olderThan: 90, home: fake)
    check("written to since the scan: refused", busy.moved.isEmpty && busy.failed == [session.url])
    check("and left where it was", fm.fileExists(atPath: session.url.path))

    let login = AIAssistants.Item(url: fake.appendingPathComponent(".claude/auth.json"),
                                  kind: .caches, bytes: 1, lastUsed: old)
    check("a login handed in directly is refused",
          AIAssistants.moveToBin([login], olderThan: nil, home: fake).moved.isEmpty
            && fm.fileExists(atPath: login.url.path))

    let escape = AIAssistants.Item(url: fake.appendingPathComponent(".claude/escape-cache"),
                                   kind: .caches, bytes: 1, lastUsed: old)
    check("a cache-named link out of home is refused",
          AIAssistants.moveToBin([escape], olderThan: nil, home: fake).moved.isEmpty
            && fm.fileExists(atPath: sandbox.appendingPathComponent("outside.txt").path))

    let july = item(".codex/sessions/2026/07/01/rollout-a.jsonl")!
    let movedDay = AIAssistants.moveToBin([july], olderThan: 90, home: fake)
    check("an old dated session goes to the Bin on its own",
          movedDay.moved == [july.url] && !fm.fileExists(atPath: july.url.path)
            && fm.fileExists(atPath: fake.appendingPathComponent(".codex/sessions/2026/10/09/rollout-b.jsonl").path))
    let binned = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/rollout-a.jsonl")
    if (try? Data(contentsOf: binned)) == Data(repeating: 7, count: 4096) { try? fm.removeItem(at: binned) }

    let cache = item(".claude/cache")!
    let done = AIAssistants.moveToBin([cache], olderThan: 90, home: fake)
    check("an old cache goes to the Bin", done.moved.count == 1 && !fm.fileExists(atPath: cache.url.path))
    // Out of the real Bin again, matched by the test's own file and content.
    let bin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    for name in ["cache"] + (1...9).map({ "cache \($0)" }) {
        let probe = bin.appendingPathComponent(name).appendingPathComponent("old.bin")
        if (try? Data(contentsOf: probe)) == Data(repeating: 7, count: 4096) {
            try? fm.removeItem(at: probe.deletingLastPathComponent())
            break
        }
    }
}

// MARK: - What an age setting withholds

print("\nWhat the age rule hides")

// The number the window needs. A filter that hides everything and says
// nothing looks like a broken scan, and on the Mac this was written against
// a 90-day rule hides all of it: every one of these directories is one the
// tool writes into constantly, so none of them is ever old.
let now = Date()
func aged(_ days: Int, _ kind: AIAssistants.Kind = .caches) -> AIAssistants.Item {
    AIAssistants.Item(url: URL(fileURLWithPath: "/tmp/roost-age-\(days)-\(kind)"),
                      kind: kind, bytes: 1_000_000,
                      lastUsed: now.addingTimeInterval(-Double(days) * 86_400))
}
let mixed = [AIAssistants.Tool(name: "mixed", items: [aged(5), aged(120), aged(400)])]

check("any age offers everything",
      AIAssistants.offered(mixed, olderThan: nil, now: now)
          .flatMap { $0.items }.count == 3)
check("and hides nothing", AIAssistants.hidden(mixed, olderThan: nil, now: now) == 0)
check("90 days offers the two older ones",
      AIAssistants.offered(mixed, olderThan: 90, now: now)
          .flatMap { $0.items }.count == 2)
check("and hides the recent one's bytes",
      AIAssistants.hidden(mixed, olderThan: 90, now: now) == 1_000_000)
check("365 days hides two of the three",
      AIAssistants.hidden(mixed, olderThan: 365, now: now) == 2_000_000)
// The case that matters: everything hidden must be reportable as a number,
// not as an empty list with no explanation.
let allRecent = [AIAssistants.Tool(name: "live", items: [aged(1), aged(2)])]
check("a rule that hides everything says how much",
      AIAssistants.hidden(allRecent, olderThan: 30, now: now) == 2_000_000
      && AIAssistants.offered(allRecent, olderThan: 30, now: now).isEmpty)

print("")
if failures == 0 { print("all passed") } else { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
