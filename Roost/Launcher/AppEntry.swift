import AppKit

/// One row in the menu.
struct AppEntry: Codable {
    let name: String
    let bundleID: String
    /// Apps that only ever launch (Launchpad), never minimize.
    var launchOnly: Bool = false
    /// Optional direct hotkey: a single character, pressed with Control.
    /// "2" means Ctrl+2 jumps straight to this app, no menu.
    var shortcut: String?
    /// Held at the top of the search list regardless of recency or search
    /// score. Launchpad is pinned by default: it is a launcher you reach for,
    /// not an app you "use", so recency ranking would always bury it.
    var pinned: Bool = false
    /// In the ⌃Tab cycle.
    ///
    /// Separate from `pinned`, which it used to share. Two unrelated things on
    /// one flag meant that pinning an app to the top of the search list also
    /// put it in the switcher -- so Launchpad, which is pinned out of the box,
    /// was silently in everyone's ⌃Tab cycle, and ⌃Tab landed on Launchpad
    /// without anyone having marked it.
    var marked: Bool = false

    enum CodingKeys: String, CodingKey {
        case name, bundleID, launchOnly, shortcut, pinned, marked
    }

    init(name: String, bundleID: String, launchOnly: Bool = false,
         shortcut: String? = nil, pinned: Bool = false, marked: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.launchOnly = launchOnly
        self.shortcut = shortcut
        self.pinned = pinned
        self.marked = marked
    }

    /// Written out rather than synthesised, because the synthesised one does
    /// not use a property's default value: a key missing from the file is a
    /// `keyNotFound` error, not a false.
    ///
    /// That is not a detail. Adding `marked` made every apps.json written
    /// before it undecodable, `load()` fell into its catch, and the list it
    /// returned instead -- the generated defaults -- replaced a list someone
    /// had curated. It destroyed mine before it was caught. Any field added
    /// after this must be decodeIfPresent too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        launchOnly = try container.decodeIfPresent(Bool.self, forKey: .launchOnly) ?? false
        shortcut = try container.decodeIfPresent(String.self, forKey: .shortcut)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        marked = try container.decodeIfPresent(Bool.self, forKey: .marked) ?? false
    }
}

/// The app list lives in a JSON file, not in the binary, so adding an app is
/// an edit and a reload rather than a rebuild.
enum Config {
    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Roost", isDirectory: true)

    static let fileURL = directory.appendingPathComponent("apps.json")

    /// The apps offered on a first run: the common ones, in the order they
    /// are usually reached for, filtered down to what the Mac actually has.
    ///
    /// This list used to be hard-coded -- and it was *my* list, with Orca,
    /// Antigravity, Discord and OpenVPN on ⌃3 through ⌃8. On anyone else's
    /// Mac that is a search panel full of apps they have never installed and
    /// six Control keys bound to nothing, with no clue that the list is just
    /// a file they can edit. Names come from the installed bundle rather than
    /// from here, so they arrive localised and correctly spelled.
    private static let candidates: [String] = [
        "com.apple.finder",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.Notes",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.Music",
        "com.spotify.client",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "us.zoom.xos",
        "notion.id",
        "com.figma.Desktop"
    ]

    /// Launchpad, which is pinned: it is a launcher you reach for rather than
    /// an app you "use", so recency ranking would always bury it. Its bundle
    /// id changed in macOS 26, so both are tried.
    private static let launchpadIDs = ["com.apple.apps.launcher", "com.apple.launchpad.launcher"]

    static var defaults: [AppEntry] {
        var entries: [AppEntry] = []

        if let launchpad = launchpadIDs.first(where: { isInstalled($0) }) {
            entries.append(AppEntry(name: name(of: launchpad) ?? "Apps",
                                    bundleID: launchpad,
                                    launchOnly: true,
                                    pinned: true))
        }

        // Only installed apps get a digit, so ⌃1 through ⌃9 always land
        // somewhere rather than being quietly dead keys.
        var digit = 1
        for bundleID in candidates where isInstalled(bundleID) {
            guard let name = name(of: bundleID) else { continue }
            let shortcut = digit <= 9 ? String(digit) : nil
            if shortcut != nil { digit += 1 }
            entries.append(AppEntry(name: name, bundleID: bundleID, shortcut: shortcut))
        }
        return entries
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func name(of bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Reads the list, writing the default file the first time.
    static func load() -> [AppEntry] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            save(defaults)
            return defaults
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return migrateMarks(try JSONDecoder().decode([AppEntry].self, from: data))
        } catch {
            // Keep what could not be read. Returning defaults here means the
            // next save overwrites the user's list with them, so a decoding
            // bug costs people a list they built by hand -- which is exactly
            // what happened when `marked` was added. A copy survives even if
            // the bug is only noticed later.
            let kept = directory.appendingPathComponent(
                "apps.json.unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: fileURL, to: kept)
            NSLog("Roost: could not read \(fileURL.path): \(error). Kept a copy at \(kept.path); using defaults.")
            return defaults
        }
    }

    private static let markMigrationKey = "appMarksSplitFromPinned"

    /// Carries old `pinned` flags over into `marked`, once.
    ///
    /// Before the two were separate, the ⌃Tab switcher read `pinned`, so an
    /// app someone added to the cycle is recorded as pinned in their file and
    /// would otherwise drop out of the cycle on upgrade. `launchOnly` entries
    /// are excluded: Launchpad is pinned by default and was never a choice
    /// anybody made, which is the bug this split fixes.
    private static func migrateMarks(_ entries: [AppEntry]) -> [AppEntry] {
        guard !UserDefaults.standard.bool(forKey: markMigrationKey) else { return entries }
        UserDefaults.standard.set(true, forKey: markMigrationKey)

        var migrated = entries
        var changed = false
        for index in migrated.indices where migrated[index].pinned
            && !migrated[index].launchOnly && !migrated[index].marked {
            migrated[index].marked = true
            changed = true
        }
        if changed { save(migrated) }
        return migrated
    }

    static func save(_ entries: [AppEntry]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Roost: could not write \(fileURL.path): \(error)")
        }
    }
}
