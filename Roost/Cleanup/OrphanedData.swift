import Foundation

/// What apps that are no longer installed left in `~/Library`.
///
/// The uninstaller answers "what did *this* app leave", for an app somebody
/// names. This answers the question nobody can ask it: what is here for apps
/// that are already gone. An app dragged to the Bin leaves its folders behind
/// and nothing ever names it again.
///
/// The test is the reverse of the uninstaller's, and so is the danger. There
/// a match has to be proved; here an *absence* has to be, and an absence is
/// easy to get wrong. Measured on one Mac, 1,142 of 1,264 entries in
/// `~/Library/Preferences` were named like a bundle identifier and LaunchServices
/// knew the app for 14 of them. Three kinds of wrong answer were in the rest:
///
/// - **Not an app at all.** `com.vercel.cli` in Application Support is a
///   command-line tool's sign-in, and no app will ever claim it. LaunchServices
///   knows apps, not tools.
/// - **Shared.** `RP2S87B72W.com.sagar.perch.widgets` (a team-ID prefix) and
///   anything starting `group.` belong to a family of apps, and another of
///   them may still be installed.
/// - **The system's.** 347 were `com.apple.*`, and `systemgroup.com.apple.…`
///   hides the same thing behind a prefix. Daemons own them, not apps.
///
/// So nothing here is decided by name alone: a name only says which
/// identifier to look up, and the place it was found decides how sure the
/// answer can be. A cache or a log is, by Apple's own contract for those
/// folders, something an app re-creates -- so a cache nobody claims is
/// offered ticked. Application Support and Preferences hold things that are
/// not re-created, a CLI's login among them, so they are shown for somebody
/// to decide on and never ticked.
enum OrphanedData {

    /// Where in `~/Library` it was found, which is what decides how safe it is.
    enum Place: String, CaseIterable {
        case caches, logs, httpStorages, webKit, applicationSupport, preferences

        var folder: String {
            switch self {
            case .caches:             return "Library/Caches"
            case .logs:               return "Library/Logs"
            case .httpStorages:       return "Library/HTTPStorages"
            case .webKit:             return "Library/WebKit"
            case .applicationSupport: return "Library/Application Support"
            case .preferences:        return "Library/Preferences"
            }
        }

        var title: String {
            switch self {
            case .caches:             return localized("Cache")
            case .logs:               return localized("Logs")
            case .httpStorages:       return localized("Web storage")
            case .webKit:             return localized("Web storage")
            case .applicationSupport: return localized("App data")
            case .preferences:        return localized("Settings")
            }
        }

        /// Whether what is here is re-created by whoever wrote it.
        ///
        /// Caches and logs only. `HTTPStorages` is cookies, and a tool's
        /// cookies can be its sign-in -- the same reason Application Support
        /// is not on the list.
        var isRecreated: Bool { self == .caches || self == .logs }
    }

    /// `~/Library/Containers` is left out, and deliberately. Since macOS 14,
    /// reading inside another app's container asks the person whether Roost
    /// may "access data from other apps" -- one prompt per container. A scan
    /// that throws up a dozen permission sheets is not a scan anybody runs
    /// twice. The uninstaller still looks there, for the one app somebody
    /// named, where one prompt is the price of an answer they asked for.
    static func roots(home: URL) -> [(place: Place, url: URL)] {
        Place.allCases.map { ($0, home.appendingPathComponent($0.folder)) }
    }

    struct Item: Equatable {
        let url: URL
        let identifier: String
        let place: Place
        let bytes: Int64
        let isMeasured: Bool

        var name: String { url.lastPathComponent }
        var isTickedByDefault: Bool { place.isRecreated }
    }

    /// What a person would call the app an identifier is for:
    /// `com.getdropbox.DropboxMetaInstaller` is "Dropbox Meta Installer".
    ///
    /// The app is gone, so there is no bundle to ask for its name; the
    /// identifier is all there is. Its last part is usually the product,
    /// split at its capitals, dashes and underscores. When that part is a
    /// generic word -- `com.vercel.cli`, `com.foo.helper` -- the maker in
    /// front of it is what tells two of them apart, so it leads.
    static func readableName(of identifier: String) -> String {
        let parts = identifier.split(separator: ".").map(String.init)
        guard let last = parts.last else { return identifier }
        let product = words(last)
        guard parts.count >= 2, generic.contains(last.lowercased()) || last.count <= 3 else {
            return product
        }
        return words(parts[parts.count - 2]) + " " + product
    }

    /// Last parts that name a role, not a product.
    static let generic: Set<String> = ["cli", "app", "helper", "agent", "daemon", "desktop",
                                       "mac", "macos", "osx", "client", "launcher", "updater",
                                       "service", "main", "plist", "prefs", "settings"]

    /// `DropboxMetaInstaller` and `dropbox-meta_installer` alike as words,
    /// with the first letter raised; an acronym run (`HTTPServer`) stays one.
    static func words(_ part: String) -> String {
        var out = ""
        let chars = Array(part)
        for (index, char) in chars.enumerated() {
            if char == "-" || char == "_" {
                if !out.hasSuffix(" ") { out.append(" ") }
                continue
            }
            if index > 0, char.isUppercase, !out.hasSuffix(" ") {
                let previous = chars[index - 1]
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                // A capital after a lower-case letter starts a word, and so
                // does the last capital of a run followed by lower case:
                // `HTTPServer` is "HTTP Server".
                if previous.isLowercase || previous.isNumber
                    || (previous.isUppercase && next?.isLowercase == true) {
                    out.append(" ")
                }
            }
            out.append(char)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        // A short lower-case part is nearly always an acronym -- `cli`,
        // `vlc`, `npm` -- and "Cli" read as a typo. "app" and "mac" are the
        // two short words that are words.
        if trimmed.count <= 3, trimmed.allSatisfy(\.isLowercase), !["app", "mac"].contains(trimmed) {
            return trimmed.uppercased()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    // MARK: - Which names are identifiers

    /// The bundle identifier a `~/Library` entry is named for, or nil if its
    /// name is not one.
    ///
    /// Three components at least: two is a vendor (`com.google`), and a
    /// vendor's folder is shared by everything it makes. Only the file-type
    /// suffixes the uninstaller already knows are stripped, for the reason
    /// written there: the last component of an identifier is not an extension.
    static func identifier(of filename: String) -> String? {
        var base = filename
        let ext = (base as NSString).pathExtension.lowercased()
        if AppLeftovers.fileSuffixes.contains(ext) { base = (base as NSString).deletingPathExtension }

        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber
                                                   || $0 == "-" || $0 == "_") })
            else { return nil }
        }
        // Reverse-DNS starts with a letter: `2024.backup.old` is not an app.
        guard parts[0].first?.isLetter == true else { return nil }
        return base
    }

    /// Identifiers this never offers, whoever does or does not claim them.
    static func isExcluded(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        // Apple's, however it is prefixed. A daemon owns these, and no
        // installed-app lookup will ever find it.
        if id.hasPrefix("com.apple.") || id.contains(".com.apple.") { return true }
        // Shared between a family of apps: an app group, or a team-ID
        // prefixed group, which is ten upper-case letters and digits.
        if id.hasPrefix("group.") || id.hasPrefix("systemgroup.") { return true }
        let first = identifier.split(separator: ".").first ?? ""
        if first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }),
           first.contains(where: \.isNumber) { return true }
        // Roost's own, and the name it had before. Perch's data is carried
        // across by `FormerName`, not left to a cleaner to guess about.
        if id.hasPrefix("com.sagar.") { return true }
        return false
    }

    // MARK: - Who claims an identifier

    /// Whether anything on this Mac still claims `identifier`.
    ///
    /// `known` is every identifier Roost found something using -- installed
    /// apps, running processes, launchd jobs -- lower-cased. `lookup` asks
    /// LaunchServices about one identifier, which also knows apps outside the
    /// Applications folders.
    ///
    /// Claimed, and so not offered, if:
    /// - it, or any identifier it is a child of, is known: data under
    ///   `com.maker.thing.helper` belongs to `com.maker.thing`;
    /// - any known identifier is a child of it: `com.microsoft.office` is the
    ///   suite's shared folder while `com.microsoft.Word` is installed.
    ///
    /// Both directions make the answer more conservative, never less: each
    /// rule can only turn an orphan into something left alone.
    static func isClaimed(_ identifier: String, known: Set<String>,
                          lookup: (String) -> Bool) -> Bool {
        let id = identifier.lowercased()
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if known.contains(candidate) { return true }
            if parts.count >= 3, lookup(candidate) { return true }
            parts.removeLast()
        }
        let prefix = id + "."
        return known.contains { $0.hasPrefix(prefix) }
    }

    /// Whether `identifier` comes from the same maker as something installed.
    ///
    /// Not a claim -- `com.getdropbox.DropboxMetaInstaller` is a finished
    /// installer whatever else Dropbox has here -- but a reason to be less
    /// sure, and so it turns a cache that would be ticked into one shown for
    /// somebody to decide on.
    static func sharesMaker(_ identifier: String, known: Set<String>) -> Bool {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return false }
        let maker = parts.prefix(2).joined(separator: ".") + "."
        return known.contains { $0.hasPrefix(maker) }
    }
}

// MARK: - Finding them

extension OrphanedData {

    /// Every identifier something on this Mac is using, lower-cased.
    ///
    /// Three sources, because each one misses things the others see:
    /// the Applications folders (an app that is installed but has never been
    /// opened is not always registered yet), running processes (a helper with
    /// no bundle in /Applications), and launchd jobs (an updater agent that
    /// is installed and runs, but is not an app -- Google's Keystone was on
    /// the measured Mac's list of "orphans" until this was added).
    static func knownIdentifiers(home: URL, running: [String]) -> Set<String> {
        var known = Set(running.map { $0.lowercased() })
        let fm = FileManager.default
        for folder in ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities",
                       home.appendingPathComponent("Applications").path] {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if let id = Bundle(url: url)?.bundleIdentifier { known.insert(id.lowercased()) }
            }
        }
        for job in BackgroundItems.jobs(home: home) {
            known.insert(job.label.lowercased())
            for id in job.associatedBundleIDs { known.insert(id.lowercased()) }
        }
        return known
    }

    /// The leftovers of apps nothing claims any more.
    ///
    /// Shallow, as the uninstaller is: an app's data sits at the top of each
    /// folder. Blocking; call it off the main thread.
    static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     known: Set<String>, lookup: (String) -> Bool,
                     shouldStop: () -> Bool = { false }) -> [Item] {
        let fm = FileManager.default
        var found: [Item] = []
        for (place, root) in roots(home: home) {
            guard !shouldStop(), let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() {
                guard let id = identifier(of: name), !isExcluded(id),
                      !isClaimed(id, known: known, lookup: lookup) else { continue }
                let url = root.appendingPathComponent(name)
                let measured = AppLeftovers.measure(url, fm: fm)
                found.append(Item(url: url, identifier: id, place: place,
                                   bytes: measured ?? 0, isMeasured: measured != nil))
            }
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
    }

    /// Whether to tick it: re-created by contract, and nothing from the same
    /// maker is installed to make that less certain.
    static func isTicked(_ item: Item, known: Set<String>) -> Bool {
        item.isTickedByDefault && !sharesMaker(item.identifier, known: known)
    }

    /// Whether `url` is still something this would offer, against the disk
    /// and the installed apps as they are now.
    ///
    /// The list on screen can be minutes old. In that time the app may have
    /// been reinstalled, which is exactly when its data stops being a
    /// leftover. So the whole test runs again: still directly inside one of
    /// the roots once symlinks are resolved, still an identifier, still not
    /// excluded, still claimed by nothing.
    static func isStillOrphaned(_ url: URL, home: URL, known: Set<String>,
                                lookup: (String) -> Bool) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let inRoot = roots(home: home).contains {
            $0.url.resolvingSymlinksInPath().standardizedFileURL.path == parent
        }
        guard inRoot, FileManager.default.fileExists(atPath: url.path),
              let id = identifier(of: url.lastPathComponent), !isExcluded(id) else { return false }
        return !isClaimed(id, known: known, lookup: lookup)
    }
}
