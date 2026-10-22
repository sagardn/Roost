import Foundation

/// What the AI coding assistants keep on disk, and which of it is safe to
/// take away while leaving the tool installed and signed in.
///
/// They are worth their own reader because of the numbers. Measured on one
/// Mac: `~/.codex` 2.4 GB, `~/.claude` 515 MB, `~/.grok` 170 MB,
/// `~/.opencode` 205 MB across five directories. Most of that is not the
/// program -- it is every conversation ever held, every file version it
/// kept, the installers it downloaded to update itself, and its logs.
///
/// **Matching is an allowlist, not a denylist.** Only names that follow a
/// known convention -- `cache`, `logs`, `sessions`, `downloads` and the rest
/// below -- are offered; anything unrecognised is left alone. A denylist
/// gets this backwards: the one entry nobody thought to exclude is
/// `auth.json`, and the cost of that mistake is somebody signed out of
/// everything with no idea why. Nothing here can reach a credential,
/// a settings file or an installed plugin, because none of them are named
/// like a cache.
enum AIAssistants {

    /// What a directory is for, which decides whether it is ticked.
    enum Kind {
        /// Conversations, memories, plans, file history. Removable, and a
        /// real loss to somebody who resumes old sessions -- so it is shown
        /// and never ticked for them.
        case conversations
        /// Rebuilt on demand. Ticked.
        case caches
        /// Ticked.
        case logs
        /// Installers the tool fetched to update itself. Ticked: it will
        /// fetch them again if it ever needs them.
        case downloads
        /// Downloaded model weights -- Hugging Face, Ollama, LM Studio.
        /// Removable, but they cost bandwidth and time to fetch again, not
        /// only space, so they are shown and never ticked.
        case models

        var label: String {
            switch self {
            case .conversations: return localized("conversations and memory")
            case .caches:        return localized("cache")
            case .logs:          return localized("logs")
            case .downloads:     return localized("downloaded updates")
            case .models:        return localized("downloaded models")
            }
        }

        /// Only what the tool can rebuild by itself, quickly and for free.
        var isTickedByDefault: Bool { self != .conversations && self != .models }
    }

    struct Item: Equatable {
        let url: URL
        let kind: Kind
        let bytes: Int64
        /// False when macOS would not say how big it is. Such an entry used
        /// to be dropped from the list entirely, because it measured zero
        /// and a zero was skipped as nothing to offer -- so a directory
        /// Roost could not open simply did not appear, however large it was.
        let isMeasured: Bool
        /// The newest modification anywhere inside -- so a folder with one
        /// file written this morning counts as used this morning, however
        /// old the rest is. Unknown is treated as now: an entry whose age
        /// cannot be read is never offered by age.
        let lastUsed: Date

        /// Where a single conversation came from, when it is one part of a
        /// store -- the project for a Claude Code session, the day for a
        /// Codex one. nil for a whole store, cache or model.
        let context: String?

        /// The assistant, for a folder that is one of its roots kept under
        /// another name -- `Library/Caches/com.todesktop.230313mzl4w4u92` is
        /// Cursor's, and its own name says so to nobody.
        var tool: String?

        var name: String { url.lastPathComponent }

        /// For a list a person reads: "Roost · 560e3c32" rather than a UUID,
        /// and "Cursor · cache" rather than a bundle identifier.
        var displayName: String {
            if context == nil, let tool { return "\(AIAssistants.title(of: tool)) · \(kind.label)" }
            guard let context else { return name }
            let looksLikeID = name.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-"#,
                                         options: .regularExpression) != nil
            return "\(context) · \(looksLikeID ? String(name.prefix(8)) : name)"
        }

        init(url: URL, kind: Kind, bytes: Int64, isMeasured: Bool = true,
             lastUsed: Date = Date(), context: String? = nil, tool: String? = nil) {
            self.url = url
            self.kind = kind
            self.bytes = bytes
            self.isMeasured = isMeasured
            self.lastUsed = lastUsed
            self.context = context
            self.tool = tool
        }

        /// Whether the age rule lets this be offered. nil is "any age".
        func isOld(enough days: Int?, now: Date = Date()) -> Bool {
            guard let days else { return true }
            return lastUsed < now.addingTimeInterval(-Double(days) * 86_400)
        }

        static func == (a: Item, b: Item) -> Bool { a.url == b.url }
    }

    struct Tool: Equatable {
        let name: String
        let items: [Item]

        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

        static func == (a: Tool, b: Tool) -> Bool { a.name == b.name }
    }

    /// What a person calls each assistant, by the name this file knows it by.
    static func title(of name: String) -> String {
        let known: [String: String] = [
            "claude": "Claude Code", "codex": "Codex", "grok": "Grok", "gemini": "Gemini",
            "copilot": "GitHub Copilot", "opencode": "OpenCode", "cursor": "Cursor",
            "windsurf": "Windsurf", "aider": "Aider", "continue": "Continue", "amp": "Amp",
            "qwen": "Qwen Code", "goose": "Goose", "crush": "Crush",
            "antigravity": "Antigravity", "chatgpt": "ChatGPT",
            "huggingface": "Hugging Face", "ollama": "Ollama", "lm studio": "LM Studio"
        ]
        return known[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The assistants this knows the shape of.
    ///
    /// A list, because there is no way to ask a directory whether it belongs
    /// to an AI tool, and guessing from the home folder would put somebody's
    /// `.ssh` one rule away from a checkbox. Adding one is a line.
    static let known = ["claude", "codex", "grok", "gemini", "copilot",
                        "opencode", "cursor", "windsurf", "aider", "continue",
                        "amp", "qwen", "goose", "crush", "antigravity", "chatgpt"]

    /// Folders a tool keeps under a name other than its own -- an app's
    /// bundle identifier, or a second product name. Relative to home.
    static let extraRoots: [String: [String]] = [
        "claude": ["Library/Caches/com.anthropic.claudefordesktop",
                   "Library/Caches/claude-cli-nodejs"],
        "chatgpt": ["Library/Application Support/com.openai.chat",
                    "Library/Caches/com.openai.chat"],
        "cursor": ["Library/Caches/com.todesktop.230313mzl4w4u92"],
        "antigravity": ["Library/Application Support/Antigravity IDE",
                        "Library/Caches/com.google.antigravity-ide"],
        "windsurf": ["Library/Caches/com.exafunction.windsurf"]
    ]

    /// Where downloaded models live, and what counts as one model.
    ///
    /// Named exactly, never matched: a model store is the largest thing an
    /// AI tool keeps and the costliest to get back, so nothing is offered
    /// from anywhere but these.
    struct ModelStore {
        let tool: String
        /// Relative to home.
        let path: String
        /// nil: the whole store is one entry. Otherwise each child whose
        /// name starts with one of these is one.
        let unitPrefixes: [String]?
    }

    static let modelStores: [ModelStore] = [
        // hub/models--org--name is self-contained: blobs, refs, snapshots.
        ModelStore(tool: "huggingface", path: ".cache/huggingface/hub",
                   unitPrefixes: ["models--", "datasets--", "spaces--"]),
        // Whole, never per blob: blobs are shared between models, and
        // removing one breaks every model whose manifest names it.
        ModelStore(tool: "ollama", path: ".ollama/models", unitPrefixes: nil),
        // models/<publisher>/<model>; a publisher folder is the unit.
        ModelStore(tool: "lm studio", path: ".lmstudio/models", unitPrefixes: [""])
    ]

    // MARK: - The rules

    /// A name with its extension taken off, lowercased.
    ///
    /// `logs_2.sqlite-wal` has an extension of `sqlite-wal`, so the base is
    /// `logs_2` and the write-ahead log travels with the database it belongs
    /// to rather than being left behind as an orphan.
    static func base(of name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    /// Conversation stores, by the names the tools actually use.
    static let conversationNames: Set<String> = [
        "projects", "sessions", "session-env", "shell-snapshots", "plans",
        "file-history", "active_sessions", "history", "prompt-history",
        "memories", "goals", "queue", "thread_history", "todos"
    ]

    static let electronCacheNames: Set<String> = [
        "code cache", "gpucache", "cacheddata", "cachedextensionvsixs",
        "cachedprofilesdata", "dawncache", "dawngraphitecache", "dawnwebgpucache",
        "shadercache", "grshadercache"
    ]

    /// `memories_1.sqlite` and `thread_history_1.sqlite` are the same thing
    /// with a schema number welded on.
    private static func withoutSchemaNumber(_ name: String) -> String {
        guard let underscore = name.lastIndex(of: "_"),
              name[name.index(after: underscore)...].allSatisfy(\.isNumber),
              name.index(after: underscore) < name.endIndex
        else { return name }
        return String(name[..<underscore])
    }

    /// What this entry is, or nil for anything not recognised -- which is
    /// most of a tool's directory, and is the point.
    static func kind(of name: String) -> Kind? {
        let base = base(of: name)
        let stem = withoutSchemaNumber(base)

        if base == "downloads" { return .downloads }
        if ["logs", "log", "telemetry"].contains(stem) { return .logs }
        if stem == "cache" || stem == "caches"
            || base.hasSuffix("-cache") || base.hasSuffix("_cache") { return .caches }
        // Electron and VS Code keep their caches under these exact names in
        // Application Support -- Claude, ChatGPT, Cursor, Antigravity and
        // Windsurf all do. Named one by one, like everything else here.
        if electronCacheNames.contains(name.lowercased()) { return .caches }
        if name.lowercased() == "crashpad" { return .logs }
        if conversationNames.contains(stem)
            || base.hasSuffix("-history") || base.hasSuffix("_history") { return .conversations }
        return nil
    }

    // MARK: - Finding it

    /// Every place one assistant keeps things.
    ///
    /// Both conventions, because they use both: the dot directory in the
    /// home folder, the XDG directories under it, and the macOS ones under
    /// `~/Library`.
    static func roots(for name: String, home: URL) -> [URL] {
        ([".\(name)", ".config/\(name)", ".local/state/\(name)",
          ".local/share/\(name)", ".cache/\(name)",
          "Library/Application Support/\(name)", "Library/Caches/\(name)",
          "Library/Logs/\(name)"] + (extraRoots[name] ?? []))
            .map { home.appendingPathComponent($0) }
    }

    /// A root that is a cache in its entirety, so its contents need no
    /// classifying: everything under `~/.cache/<tool>` is a cache by
    /// definition, whatever the tool called the directories inside it.
    static func isWhollyCache(_ url: URL, home: URL) -> Bool {
        let path = url.path
        return path.hasPrefix(home.appendingPathComponent(".cache").path + "/")
            || path.hasPrefix(home.appendingPathComponent("Library/Caches").path + "/")
            || path.hasPrefix(home.appendingPathComponent("Library/Logs").path + "/")
    }

    /// What every known assistant on this Mac is holding. Blocking.
    static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Tool] {
        let fm = FileManager.default
        var tools: [Tool] = []

        for name in known.sorted() {
            var items: [Item] = []

            for root in roots(for: name, home: home) {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                if isWhollyCache(root, home: home) {
                    let measured = AppLeftovers.measure(root, fm: fm)
                    if measured != 0 {
                        items.append(Item(url: root,
                                          kind: root.path.contains("/Logs/") ? .logs : .caches,
                                          bytes: measured ?? 0,
                                          isMeasured: measured != nil,
                                          lastUsed: lastModified(root),
                                          tool: name))
                    }
                    continue
                }

                for entry in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
                    guard let kind = kind(of: entry) else { continue }
                    let url = root.appendingPathComponent(entry)
                    // A conversation store is offered a conversation at a
                    // time, so the age rule can retire an old session while
                    // today's stays. Judged whole, by its newest file, a
                    // store any live tool writes into is always "used
                    // today" -- measured: nothing on this Mac was older than
                    // 26 days, so every age setting showed an empty list.
                    if kind == .conversations, let units = conversationUnits(url) {
                        for unit in units {
                            let measured = AppLeftovers.measure(unit.url, fm: fm)
                            guard measured != 0 else { continue }
                            items.append(Item(url: unit.url, kind: .conversations,
                                              bytes: measured ?? 0, isMeasured: measured != nil,
                                              lastUsed: lastModified(unit.url), context: unit.context))
                        }
                        continue
                    }
                    let measured = AppLeftovers.measure(url, fm: fm)
                    // A store that really is empty is nothing to offer and
                    // nothing to free; it only lengthens the list. One that
                    // would not answer is kept, because the reason it would
                    // not answer is not that it is small.
                    guard measured != 0 else { continue }
                    items.append(Item(url: url, kind: kind, bytes: measured ?? 0,
                                      isMeasured: measured != nil,
                                      lastUsed: lastModified(url)))
                }
            }

            if !items.isEmpty {
                tools.append(Tool(name: name, items: items.sorted { $0.bytes > $1.bytes }))
            }
        }

        for store in modelStores {
            let items = modelUnits(store, home: home).compactMap { url -> Item? in
                let measured = AppLeftovers.measure(url, fm: fm)
                guard measured != 0 else { return nil }
                return Item(url: url, kind: .models, bytes: measured ?? 0,
                            isMeasured: measured != nil, lastUsed: lastModified(url))
            }
            if !items.isEmpty {
                tools.append(Tool(name: store.tool, items: items.sorted { $0.bytes > $1.bytes }))
            }
        }

        return tools.sorted { $0.bytes > $1.bytes }
    }

    /// The single conversations a store holds, or nil when it is a file
    /// (a history.jsonl is one unit already).
    ///
    /// - `projects` (Claude Code): each session in each project. A project's
    ///   `memory` folder is what the person taught the tool and is never a
    ///   unit -- it is not offered at all.
    /// - Folders named by date (Codex's `sessions/2026/10/11`): walked down
    ///   to what is inside the day, so a year folder is not a unit that is
    ///   "used today" for twelve months.
    /// - Anything else: each item in the store.
    static func conversationUnits(_ store: URL) -> [(url: URL, context: String?)]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: store.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        func children(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted().filter { !$0.hasPrefix(".") }
        }
        func isFolder(_ url: URL) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
        }
        func isDated(_ name: String) -> Bool { !name.isEmpty && name.allSatisfy(\.isNumber) }

        var units: [(URL, String?)] = []
        func walk(_ url: URL, dated: [String]) {
            for name in children(url) where name.lowercased() != "memory" {
                let child = url.appendingPathComponent(name)
                if isDated(name), isFolder(child) {
                    walk(child, dated: dated + [name])
                } else {
                    units.append((child, dated.isEmpty ? nil : dated.joined(separator: "-")))
                }
            }
        }
        if store.lastPathComponent == "projects" {
            for project in children(store) {
                let folder = store.appendingPathComponent(project)
                guard isFolder(folder) else { continue }
                // Claude Code names a project after its path with "/" as "-":
                // "-Users-amit-Desktop-project-Roost" is the Roost project.
                let label = project.split(separator: "-").last.map(String.init) ?? project
                for name in children(folder) where name.lowercased() != "memory" {
                    units.append((folder.appendingPathComponent(name), label))
                }
            }
        } else {
            walk(store, dated: [])
        }
        return units
    }

    /// The entries one model store is split into.
    static func modelUnits(_ store: ModelStore, home: URL) -> [URL] {
        let root = home.appendingPathComponent(store.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard let prefixes = store.unitPrefixes else { return [root] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .sorted()
            .filter { name in !name.hasPrefix(".") && prefixes.contains { name.hasPrefix($0) } }
            .map { root.appendingPathComponent($0) }
    }

    // MARK: - Age

    /// What an age setting is withholding, in bytes.
    ///
    /// The window needs this to avoid the worst outcome a filter has, which
    /// is looking like a failure. Measured on one Mac: the scan finds
    /// 2.72 GB and a 90-day rule offers none of it, because every one of
    /// these directories is one the tool writes into constantly -- the
    /// oldest file in ~/.claude/projects is three weeks old and something in
    /// it was written this morning, so all 462 MB counts as used today. An
    /// empty list with no explanation reads as "the scan is broken"; "2.7 GB
    /// hidden by the 90-day rule" reads as a setting, which is what it is.
    static func hidden(_ tools: [Tool], olderThan days: Int?, now: Date = Date()) -> Int64 {
        let shown = Set(offered(tools, olderThan: days, now: now)
            .flatMap { $0.items }.map { $0.url })
        return tools.flatMap { $0.items }
            .filter { !shown.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// The tools with only what the age rule lets through. nil is any age.
    static func offered(_ tools: [Tool], olderThan days: Int?, now: Date = Date()) -> [Tool] {
        tools.compactMap { tool in
            let items = tool.items.filter { $0.isOld(enough: days, now: now) }
            return items.isEmpty ? nil : Tool(name: tool.name, items: items)
        }
    }

    /// The newest modification anywhere inside `url`, read from the disk now.
    ///
    /// A fresh URL every time, never the one passed in: Foundation caches
    /// resource values on a URL object, so re-reading a URL that the scan
    /// already read gives back the scan's dates -- and the check before the
    /// Bin passed a session written to a second earlier. Symlinks are not
    /// followed: a link counts as a link.
    static func lastModified(_ url: URL) -> Date {
        let url = URL(fileURLWithPath: url.path)
        let key: URLResourceKey = .contentModificationDateKey
        var newest = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate ?? .distantPast
        if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key],
                                                     options: [], errorHandler: { _, _ in true }) {
            for case let child as URL in walk {
                if let date = (try? child.resourceValues(forKeys: [key]))?.contentModificationDate,
                   date > newest { newest = date }
            }
        }
        return newest
    }

    // MARK: - Checked again before the Bin

    /// Whether `url` is still something this offers: inside home once every
    /// symlink is resolved, and reached by the same allowlist the scan uses
    /// -- a recognised name directly inside a known root, a root that is a
    /// cache in its entirety, or a unit of a named model store.
    static func isOfferable(_ url: URL, home: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.path.hasPrefix(homePath + "/") else { return false }

        let path = url.standardizedFileURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        for name in known {
            for root in roots(for: name, home: home) {
                let rootPath = root.standardizedFileURL.path
                if path == rootPath, isWhollyCache(root, home: home) { return true }
                if parent == rootPath, !isWhollyCache(root, home: home),
                   kind(of: url.lastPathComponent) != nil { return true }
            }
        }
        // One conversation out of a store directly inside a known root.
        for name in known {
            for root in roots(for: name, home: home) where !isWhollyCache(root, home: home) {
                let rootPath = root.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let store = String(path.dropFirst(rootPath.count + 1)).split(separator: "/").first.map(String.init) ?? ""
                guard kind(of: store) == .conversations,
                      let units = conversationUnits(root.appendingPathComponent(store)) else { continue }
                if units.contains(where: { $0.url.standardizedFileURL.path == path }) { return true }
            }
        }
        return modelStores.contains { modelUnits($0, home: home).map(\.standardizedFileURL.path).contains(path) }
    }

    /// Every item checked again against the disk as it is now -- still
    /// offerable, still inside home, and still old enough -- and only those
    /// moved. The rest are reported as failed and left exactly where they
    /// were. The list on screen can be minutes old; the disk is not.
    static func moveToBin(_ items: [Item], olderThan days: Int?,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          now: Date = Date()) -> LargeFiles.Removal {
        var refused: [URL] = []
        var cleared: [Item] = []
        for item in items {
            let stillOld = days.map { lastModified(item.url) < now.addingTimeInterval(-Double($0) * 86_400) } ?? true
            if FileManager.default.fileExists(atPath: item.url.path),
               isOfferable(item.url, home: home), stillOld {
                cleared.append(item)
            } else {
                refused.append(item.url)
            }
        }
        var removal = LargeFiles.moveToBin(cleared.map { LargeFiles.Item(url: $0.url, bytes: $0.bytes) })
        removal.failed += refused
        return removal
    }

    /// To the Bin, like everything else Roost removes. A conversation store
    /// somebody wanted back is then a trip to Finder.
    /// Any age, but every other check still made -- see the full form.
    static func moveToBin(_ items: [Item]) -> LargeFiles.Removal {
        moveToBin(items, olderThan: nil)
    }
}
