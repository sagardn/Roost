import Foundation

/// One scan that asks every finder at once, and one list to act on.
///
/// The Check-up has no finding logic of its own. It runs what the rest of
/// `Roost/Cleanup/` and `Roost/System/` already know how to find -- leftovers
/// of removed apps (`OrphanedData`), finished downloads (`StaleDownloads`),
/// AI tools' caches (`AIAssistants`), duplicates (`Duplicates`), macOS's
/// protections (`Protection`) and what starts by itself (`BackgroundItems`)
/// -- and turns the lot into advice through `Recommendations`. Each of those
/// keeps its own rules and its own tests; this only gathers, merges and
/// hands the Bin what was chosen.
///
/// Three rules it adds, each about the seams between the finders:
///
/// - **One row per file.** Two finders can reach the same folder -- an AI
///   app's cache is also an orphan once the app is gone -- and a file listed
///   twice is a file counted twice in the total.
/// - **Checked again at the Bin, by the finder that found it.** The list can
///   be minutes old. An app reinstalled since, a download resumed, a file
///   written to: each is refused and left where it is.
/// - **Moved is not freed.** Everything goes to the Bin, where it still
///   takes the same space until the Bin is emptied. The result says what was
///   moved, measured as it was moved, and never calls it space reclaimed.
enum CheckUp {

    enum Section: Int, CaseIterable {
        case leftovers, downloads, assistants

        var title: String {
            switch self {
            case .leftovers:  return localized("Left by removed apps")
            case .downloads:  return localized("Finished downloads")
            case .assistants: return localized("AI tool caches")
            }
        }

        var explanation: String {
            switch self {
            case .leftovers:
                // Settings and app data are not ticked because a command-line
                // tool, which no installed app will ever claim, can keep its
                // sign-in there -- `com.vercel.cli` did, on the Mac measured.
                return localized("Data named for apps that are no longer installed. Caches and logs are ticked; settings and app data are for you to check.")
            case .downloads:
                return localized("Installers in Downloads, and downloads that stopped and never finished. Installers over a month old are ticked.")
            case .assistants:
                return localized("Caches, logs and downloaded updates the tools rebuild by themselves. Conversations and models are not listed here.")
            }
        }

        var symbol: String {
            switch self {
            case .leftovers:  return "shippingbox"
            case .downloads:  return "arrow.down.circle"
            case .assistants: return "sparkles"
            }
        }
    }

    /// The rules a scan was made under, kept so the check before the Bin is
    /// made under the same ones.
    struct Context {
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        /// Every identifier something installed or running is using.
        var known: Set<String> = []
        /// LaunchServices, asked about one identifier.
        var lookup: (String) -> Bool = { _ in false }
        /// Disk images attached at the scan.
        var mounted: Set<String> = []
        /// The AI window's "unused for" rule, so the Check-up never ticks a
        /// cache that window would hide. nil is any age.
        var assistantDays: Int?

        var downloads: URL { home.appendingPathComponent("Downloads") }
    }

    enum Source: Equatable {
        case leftover(OrphanedData.Item)
        case download(StaleDownloads.Item)
        case assistant(AIAssistants.Item)
    }

    struct Entry: Equatable {
        let source: Source
        /// Whether it arrives ticked, by the rule of the finder that found it.
        let isTickedByDefault: Bool

        var section: Section {
            switch source {
            case .leftover:  return .leftovers
            case .download:  return .downloads
            case .assistant: return .assistants
            }
        }

        var url: URL {
            switch source {
            case .leftover(let item):  return item.url
            case .download(let item):  return item.url
            case .assistant(let item): return item.url
            }
        }

        var bytes: Int64 {
            switch source {
            case .leftover(let item):  return item.bytes
            case .download(let item):  return item.bytes
            case .assistant(let item): return item.bytes
            }
        }

        var isMeasured: Bool {
            switch source {
            case .leftover(let item):  return item.isMeasured
            case .download:            return true
            case .assistant(let item): return item.isMeasured
            }
        }

        var name: String {
            switch source {
            case .assistant(let item): return item.displayName
            // A file name like `com.getdropbox.DropboxMetaInstaller.plist`
            // asked a person to read reverse-DNS to judge a row; the
            // identifier stays on the line underneath for whoever wants it.
            case .leftover(let item):  return OrphanedData.readableName(of: item.identifier)
            case .download:            return url.lastPathComponent
            }
        }

        /// The exact thing on disk, when the name is not it.
        var detail: String? {
            switch source {
            case .leftover(let item): return item.identifier
            default:                  return nil
            }
        }

        /// What it is, in a word or two, for the line under its name.
        var label: String {
            switch source {
            case .leftover(let item):
                return item.place.title
            case .download(let item):
                // The age is what decides the tick, so it is said: without
                // it, one installer ticked and the next not looked arbitrary.
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let ago = formatter.localizedString(for: item.added, relativeTo: Date())
                return item.kind == .installer ? localized("Installer, added %0", ago)
                                               : localized("Unfinished download, stopped %0", ago)
            case .assistant(let item):
                return item.kind.label
            }
        }
    }

    /// The finders' results as one list: deduplicated by URL, in section
    /// order, biggest first within a section.
    ///
    /// AI conversations and downloaded models are left out and counted
    /// instead. Losing a conversation costs somebody work and losing a model
    /// costs a long download, and their own window -- where conversations are
    /// grouped by project, and nothing is ticked -- is where that choice
    /// belongs, not one more row in a list of caches.
    ///
    /// `assistants` is everything the AI finders reached, before the age rule;
    /// `assistantDays` is that rule, applied here and only to which of them
    /// are offered. The guards below need the whole list. Given the filtered
    /// one, as they were, a conversation saved this week was not in it -- so
    /// it protected nothing, and an uninstalled ChatGPT's whole
    /// `com.openai.chat` folder, sessions and all, came back as a leftover
    /// one tick away from the Bin. A cache the age rule had just hidden came
    /// back the same way, ticked.
    static func entries(leftovers: [OrphanedData.Item], downloads: [StaleDownloads.Item],
                        assistants: [AIAssistants.Item], assistantDays: Int? = nil,
                        known: Set<String>,
                        now: Date = Date()) -> (entries: [Entry], heldBack: Int64) {
        var seen = Set<String>()
        var out: [Entry] = []
        var heldBack: Int64 = 0
        let canonical = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
        // Every folder an AI finder reached, listed or held back. A leftover
        // that *contains* one is not offered: an uninstalled ChatGPT's
        // `Application Support/com.openai.chat` holds its saved sessions, and
        // ticking that one row would move the conversations this list
        // promises to leave out -- and count the cache inside it twice.
        let assistantPaths = assistants.map { canonical($0.url) }

        func add(_ entry: Entry) {
            // Resolved, so `/private/var/x` and `/var/x` are one file.
            let key = entry.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            out.append(entry)
        }

        // Every one claimed first, offered or not, so the orphan finder can
        // list none of them again under another name.
        for item in assistants { seen.insert(canonical(item.url)) }
        var offered = Set<String>()
        for item in assistants {
            if item.kind == .conversations || item.kind == .models {
                heldBack += item.bytes
                continue
            }
            guard item.isOld(enough: assistantDays, now: now),
                  offered.insert(canonical(item.url)).inserted else { continue }
            out.append(Entry(source: .assistant(item), isTickedByDefault: item.kind.isTickedByDefault))
        }
        for item in leftovers {
            let path = canonical(item.url)
            if assistantPaths.contains(where: { $0.hasPrefix(path + "/") }) { continue }
            add(Entry(source: .leftover(item), isTickedByDefault: OrphanedData.isTicked(item, known: known)))
        }
        for item in downloads {
            add(Entry(source: .download(item), isTickedByDefault: StaleDownloads.isTickedByDefault(item, now: now)))
        }

        let sorted = out.enumerated().sorted { a, b in
            if a.element.section != b.element.section {
                return a.element.section.rawValue < b.element.section.rawValue
            }
            if a.element.bytes != b.element.bytes { return a.element.bytes > b.element.bytes }
            return a.offset < b.offset
        }.map(\.element)
        return (sorted, heldBack)
    }
}

// MARK: - The report

extension CheckUp {

    struct Report {
        var finished: Date
        var entries: [Entry] = []
        /// AI conversations and models, not listed; see `entries(…)`.
        var heldBack: Int64 = 0
        var duplicates: Duplicates.Scan?
        var protection: Protection.Report?
        var jobs: [BackgroundItems.Assessed] = []
        var disk: DiskReadings.Volume?
        var memoryPressure: MemoryReadings.Pressure?
        var thermalState: Int?
        /// False when the scan was stopped before every stage ran.
        var isComplete = true

        var tickedBytes: Int64 { entries.filter(\.isTickedByDefault).reduce(0) { $0 + $1.bytes } }
        var reviewBytes: Int64 { entries.filter { !$0.isTickedByDefault }.reduce(0) { $0 + $1.bytes } }

        var jobsMissingProgram: Int { jobs.filter { $0.concerns.contains(.programMissing) }.count }
        var jobsUnsigned: Int {
            jobs.filter { $0.concerns.contains(.unsigned) || $0.concerns.contains(.brokenSignature) }.count
        }

        /// What the advice engine is given. A stage that did not run is nil,
        /// so it says nothing rather than reporting that stage as fine.
        var inputs: Recommendations.Inputs {
            var inputs = Recommendations.Inputs()
            inputs.disk = disk
            inputs.memoryPressure = memoryPressure
            inputs.thermalState = thermalState
            inputs.cleanupTicked = tickedBytes
            inputs.cleanupReview = reviewBytes
            if let duplicates {
                inputs.duplicateBytes = duplicates.groups.reduce(0) { $0 + $1.reclaimable }
                inputs.duplicateGroups = duplicates.groups.count
            }
            inputs.protection = protection
            if !jobs.isEmpty {
                inputs.jobsMissingProgram = jobsMissingProgram
                inputs.jobsUnsigned = jobsUnsigned
            }
            return inputs
        }

        var recommendations: [Recommendations.Recommendation] { Recommendations.make(inputs) }
    }

    /// How long a report is reused before a new scan is worth its cost. The
    /// duplicate walk alone reads every large file's first block; reopening
    /// the window a minute later should not repeat that.
    static let freshFor: TimeInterval = 15 * 60

    /// Whether `report` can be shown again instead of scanning: young enough,
    /// complete, and nothing has been moved to the Bin since it was made --
    /// a move changes what is on the disk, and a report that predates it
    /// lists files that are gone.
    ///
    /// And every row is still on the disk. The other cleanup windows move
    /// things too, and a report that lists a file Large files has already
    /// moved would show it, total it and advise on it; asking the disk covers
    /// every window without each one having to report its moves here.
    static func isFresh(_ report: Report?, lastMove: Date?, now: Date = Date(),
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        guard let report, report.isComplete else { return false }
        if let lastMove, lastMove >= report.finished { return false }
        guard now.timeIntervalSince(report.finished) < freshFor else { return false }
        return report.entries.allSatisfy { exists($0.url) }
    }

    enum Stage: Int, CaseIterable {
        case leftovers, downloads, assistants, duplicates, protection, background

        var title: String {
            switch self {
            case .leftovers:  return localized("Looking for what removed apps left")
            case .downloads:  return localized("Looking in Downloads")
            case .assistants: return localized("Looking at AI tools")
            case .duplicates: return localized("Comparing files")
            case .protection: return localized("Checking macOS protections")
            case .background: return localized("Checking what runs in the background")
            }
        }
    }

    /// Every stage, in order. Blocking; off the main thread.
    ///
    /// `lookup` and `running` come from the caller because they are AppKit's
    /// (`NSWorkspace`), and this file is compiled into a test that has no
    /// workspace to ask.
    ///
    /// `context` arrives with `home`, `lookup` and `assistantDays` set; the
    /// scan fills in `known` and `mounted` and hands it back, for the Bin.
    static func run(context: Context, running: [String],
                    appURL: @escaping (String) -> URL?,
                    duplicateDeadline: TimeInterval = 20,
                    shouldStop: () -> Bool = { false },
                    stage: (Stage) -> Void = { _ in }) -> (report: Report, context: Context) {
        var context = context
        let home = context.home
        var report = Report(finished: Date())
        context.known = OrphanedData.knownIdentifiers(home: home, running: running)
        context.mounted = StaleDownloads.mountedImages()

        stage(.leftovers)
        let leftovers = OrphanedData.find(home: home, known: context.known, lookup: context.lookup,
                                          shouldStop: shouldStop)
        guard !shouldStop() else { return (stopped(report), context) }

        stage(.downloads)
        let downloads = StaleDownloads.find(in: context.downloads, mounted: context.mounted)
        guard !shouldStop() else { return (stopped(report), context) }

        stage(.assistants)
        let assistants = AIAssistants.find(home: home).flatMap(\.items)
        guard !shouldStop() else { return (stopped(report), context) }

        let merged = entries(leftovers: leftovers, downloads: downloads, assistants: assistants,
                             assistantDays: context.assistantDays, known: context.known)
        report.entries = merged.entries
        report.heldBack = merged.heldBack

        stage(.duplicates)
        report.duplicates = Duplicates.scan(roots: LargeFiles.defaultRoots(home: home),
                                            deadline: Date().addingTimeInterval(duplicateDeadline),
                                            shouldStop: shouldStop)
        guard !shouldStop() else { return (stopped(report), context) }

        stage(.protection)
        report.protection = Protection.read()

        stage(.background)
        report.jobs = BackgroundItems.assessAll(home: home, appURL: appURL)

        report.disk = DiskReadings.primary()
        report.memoryPressure = MemoryReadings.pressure()
        report.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        // When it finished, not when it started: freshness is measured from
        // the newest thing it read.
        report.finished = Date()
        return (report, context)
    }

    private static func stopped(_ report: Report) -> Report {
        var copy = report
        copy.isComplete = false
        return copy
    }
}

// MARK: - To the Bin

extension CheckUp {

    struct Outcome: Equatable {
        /// What went, and how big each was when it went.
        var moved: [(url: URL, bytes: Int64)] = []
        /// Refused by the check before the Bin: changed since the scan.
        var refused: [URL] = []
        /// The move itself failed -- locked, in use, no Bin on that volume --
        /// with what macOS said.
        var failed: [(url: URL, reason: String)] = []

        var bytesMoved: Int64 { moved.reduce(0) { $0 + $1.bytes } }

        static func == (a: Outcome, b: Outcome) -> Bool {
            a.moved.map(\.url) == b.moved.map(\.url) && a.moved.map(\.bytes) == b.moved.map(\.bytes)
                && a.refused == b.refused && a.failed.map(\.url) == b.failed.map(\.url)
        }
    }

    /// Whether `entry` is still what the scan found, asked of the finder that
    /// found it.
    static func isStillOffered(_ entry: Entry, in context: Context, now: Date = Date()) -> Bool {
        switch entry.source {
        case .leftover(let item):
            return OrphanedData.isStillOrphaned(item.url, home: context.home, known: context.known,
                                                lookup: context.lookup)
        case .download(let item):
            return StaleDownloads.isUnchanged(item, in: context.downloads, mounted: context.mounted)
        case .assistant(let item):
            guard FileManager.default.fileExists(atPath: item.url.path),
                  AIAssistants.isOfferable(item.url, home: context.home) else { return false }
            // Used since the scan is used: the age rule is read off the disk
            // again, as the AI window's own Bin does.
            guard let days = context.assistantDays else { return true }
            return AIAssistants.lastModified(item.url) < now.addingTimeInterval(-Double(days) * 86_400)
        }
    }

    /// Moves `entries` to the Bin, each checked again first, each measured
    /// again just before it goes so the figure reported is what moved and
    /// not what the scan saw.
    ///
    /// `trash` is `FileManager.trashItem` in the app; a test passes a move
    /// into a scratch folder, so the checks can be exercised without filling
    /// the developer's Bin. Every move is written to the unified log through
    /// `log`, with where it went, so "what did the cleanup remove" has an
    /// answer after the window is closed.
    static func moveToBin(_ entries: [Entry], in context: Context,
                          trash: (URL) throws -> URL?,
                          log: (String) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        for entry in entries {
            guard isStillOffered(entry, in: context) else {
                outcome.refused.append(entry.url)
                log("Check-up: left \(entry.url.path) -- changed since the scan")
                continue
            }
            let bytes = AppLeftovers.measure(entry.url, fm: .default) ?? entry.bytes
            do {
                let landed = try trash(entry.url)
                outcome.moved.append((entry.url, bytes))
                log("Check-up: moved \(entry.url.path) (\(bytes) bytes) to \(landed?.path ?? "the Bin")")
            } catch {
                outcome.failed.append((entry.url, error.localizedDescription))
                log("Check-up: could not move \(entry.url.path): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// The real Bin.
    static func trashItem(_ url: URL) throws -> URL? {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }
}
