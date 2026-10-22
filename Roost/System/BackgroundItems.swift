import Foundation
import Security

/// What starts by itself: the launchd jobs in the three folders anything
/// installed by a person or an installer goes into.
///
/// This is what macOS's Login Items settings list under "Allow in the
/// Background", read from the files themselves. It is a list, not a
/// switchboard, and the line is drawn by what the public API allows:
///
/// - **Login items cannot be listed.** Apps added with `SMAppService` or the
///   old shared file list live in the Background Task Management database,
///   which only `sfltool` reads, and only as root. Roost does not pretend to
///   show them; it opens the settings page that does.
/// - **Turning a job off is not done here.** `launchctl disable` for another
///   app's job, or editing its plist, is changing someone else's software
///   behind its back, and the job's own app may simply put it back. System
///   Settings has the switch, and it is the switch that app expects.
///
/// What it adds over that page is *evidence*: which program a job runs,
/// whether that program is still there, and who signed it. Those are the
/// facts a person needs to decide whether `com.example.helper` is theirs.
enum BackgroundItems {

    /// Which of the three folders a job's plist is in.
    enum Domain: Int, CaseIterable {
        /// `~/Library/LaunchAgents`: runs as this user, and this user can
        /// remove it.
        case user
        /// `/Library/LaunchAgents`: runs as every user who logs in.
        case allUsers
        /// `/Library/LaunchDaemons`: runs as root, before anyone logs in.
        case system

        func folder(home: URL) -> URL {
            switch self {
            case .user:     return home.appendingPathComponent("Library/LaunchAgents")
            case .allUsers: return URL(fileURLWithPath: "/Library/LaunchAgents")
            case .system:   return URL(fileURLWithPath: "/Library/LaunchDaemons")
            }
        }

        var title: String {
            switch self {
            case .user:     return localized("For you")
            case .allUsers: return localized("For every user")
            case .system:   return localized("For the system")
            }
        }
    }

    struct Job: Equatable {
        let plist: URL
        let domain: Domain
        let label: String
        /// `Program`, or the first of `ProgramArguments`.
        let program: String?
        let arguments: [String]
        /// `BundleProgram`: a path inside the app named by
        /// `AssociatedBundleIdentifiers`, which is how `SMAppService` jobs say
        /// what they run.
        let bundleProgram: String?
        let associatedBundleIDs: [String]
        let runsAtLoad: Bool
        let keepsAlive: Bool
        /// `StartInterval`, in seconds.
        let interval: Int?
        /// The plist's own `Disabled` key. launchd keeps a second, separate
        /// record of jobs switched off with `launchctl disable`, which only it
        /// can read, so false here does not prove the job runs.
        let disabledInPlist: Bool
    }

    /// The job a launchd plist describes, or nil if it does not describe one.
    ///
    /// Separated from the reading so it can be checked against dictionaries
    /// written down: the shapes launchd accepts are several, and `KeepAlive`
    /// alone can be a bool or a dictionary of conditions.
    static func parse(_ plist: [String: Any], at url: URL, domain: Domain) -> Job? {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        let program = (plist["Program"] as? String) ?? arguments.first
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let flag as Bool:           keepAlive = flag
        // A dictionary of conditions -- "keep it alive while the network is
        // up" -- is still a job that is restarted when it exits.
        case let conditions as [String: Any]: keepAlive = !conditions.isEmpty
        default:                         keepAlive = false
        }
        let associated: [String]
        switch plist["AssociatedBundleIdentifiers"] {
        case let one as String:   associated = [one]
        case let many as [String]: associated = many
        default:                  associated = []
        }
        return Job(plist: url, domain: domain, label: label, program: program,
                   arguments: arguments, bundleProgram: plist["BundleProgram"] as? String,
                   associatedBundleIDs: associated,
                   runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                   keepsAlive: keepAlive,
                   interval: plist["StartInterval"] as? Int,
                   disabledInPlist: plist["Disabled"] as? Bool ?? false)
    }

    /// Every job in the three folders, by label.
    ///
    /// The two system folders are root's to write and everyone's to read, so
    /// listing them needs no permission. A plist that does not parse is
    /// skipped rather than reported: launchd skips it too.
    static func jobs(home: URL) -> [Job] {
        let fm = FileManager.default
        var found: [Job] = []
        for domain in Domain.allCases {
            let folder = domain.folder(home: home)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".plist") {
                let url = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any],
                      let job = parse(dict, at: url, domain: domain) else { continue }
                found.append(job)
            }
        }
        return found.sorted {
            $0.domain != $1.domain ? $0.domain.rawValue < $1.domain.rawValue
                                   : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }
}

// MARK: - What it runs

extension BackgroundItems {

    /// Who signed a program, as far as the signature says.
    enum Signature: Equatable {
        case apple
        case developer(team: String)
        /// Signed, but with no team: ad hoc, or self-signed. Homebrew builds
        /// and anything compiled on this Mac look like this, so it is shown,
        /// not alarmed about.
        case adHoc
        case unsigned
        /// Signed, and the signature no longer matches the file.
        case broken
        /// The file is not there to check.
        case missing
        /// The file may well be there, but a folder on the way to it is
        /// closed to this user, so neither its signature nor its absence can
        /// be known.
        case unreadable
    }

    /// Whether `path` is known to be absent: the system says there is no
    /// such file. `fileExists` also answers false for a file it is merely not
    /// allowed to look at -- tested on one inside a `chmod 000` folder -- and
    /// "missing" is what offers a job for the Bin.
    static func isAbsent(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// Whether `path` can be examined at all.
    private static func isReachable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// Interpreters a job can hand a script to. The interpreter is Apple's
    /// and correctly signed; the script it runs is not signed by anyone, and
    /// a signature check on the interpreter says nothing about it.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh",
        "python", "python3", "perl", "ruby", "osascript", "node", "env"
    ]

    /// The file the job runs, as an absolute path.
    ///
    /// `BundleProgram` is relative to the associated app's bundle, which
    /// only LaunchServices can locate -- hence `appURL`.
    ///
    /// A bare name -- `["sh", "-c", …]` -- is looked up the way launchd looks
    /// it up, in `_PATH_STDPATH` (`man launchd.plist`). Treating it as
    /// missing called a working job broken and hid the script it runs.
    static func executable(of job: Job, appURL: (String) -> URL?,
                           exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        if let relative = job.bundleProgram {
            for id in job.associatedBundleIDs {
                if let app = appURL(id) { return app.appendingPathComponent(relative) }
            }
            return nil
        }
        guard let program = job.program, !program.isEmpty else { return nil }
        if program.hasPrefix("/") { return URL(fileURLWithPath: program) }
        guard !program.contains("/") else { return nil }
        for folder in standardPath {
            let candidate = folder + "/" + program
            if exists(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// `_PATH_STDPATH` from `<paths.h>`.
    static let standardPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Who signed `url`.
    ///
    /// Resources are not validated: that hashes every file in a bundle, and a
    /// launch agent's program is a single executable. Measured here, a check
    /// costs under 12 ms this way. Symlinks are resolved first --
    /// `SecStaticCodeCreateWithPath` refuses Homebrew's `/opt/homebrew/bin`
    /// links rather than following them.
    static func signature(of url: URL) -> Signature { inspect(url).signature }

    /// Who signed `url`, and the name on the certificate that signed it.
    ///
    /// The name is what makes a team ID mean something: `EQHXZ8M8AV` is
    /// nobody's idea of an answer, "Google LLC" is. It comes from the same
    /// signing information as the team, so it costs nothing more.
    static func inspect(_ url: URL) -> (signature: Signature, signer: String?) {
        let resolved = url.resolvingSymlinksInPath()
        if isAbsent(resolved.path) { return (.missing, nil) }
        guard isReachable(resolved.path) else { return (.unreadable, nil) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &code) == errSecSuccess,
              let code else { return (.unsigned, nil) }

        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        switch SecStaticCodeCheckValidity(code, flags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return (.unsigned, nil)
        default: return (.broken, nil)
        }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess {
            return (.apple, nil)
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any]
        if let team = dict?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            // The leaf is first in the chain, and it is the one with the
            // developer's name on it; the others are Apple's CAs.
            let leaf = (dict?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            return (.developer(team: team), summary.flatMap(signer(fromSummary:)))
        }
        return (.adHoc, nil)
    }

    /// The developer's name out of a certificate's subject summary --
    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" is "Google LLC".
    ///
    /// The kind before the colon and the team in brackets are both dropped:
    /// the kind is the same on nearly every row, and the team is already
    /// known. A summary not in that shape is used as it is rather than
    /// guessed at.
    static func signer(fromSummary summary: String) -> String? {
        var name = Substring(summary)
        if let colon = name.range(of: ": ") { name = name[colon.upperBound...] }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = name[..<open.lowerBound]
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The app a program belongs to: the outermost `.app` in its path.
    ///
    /// Outermost, because a helper is often an app inside an app --
    /// `Foo.app/Contents/Library/LoginItems/FooHelper.app` -- and the one a
    /// person installed, and recognises, is `Foo.app`.
    static func owningApp(of executable: URL) -> URL? {
        var path = ""
        for component in executable.standardizedFileURL.pathComponents {
            path = path.isEmpty || path == "/" ? path + component : path + "/" + component
            if component.hasSuffix(".app") { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// What a row is called: the app it belongs to, else the program's own
    /// file name, else the label -- which is what launchd calls it and is
    /// shown underneath anyway.
    static func title(of item: Assessed) -> String {
        if let app = item.app {
            return (app.lastPathComponent as NSString).deletingPathExtension
        }
        if let name = item.executable?.lastPathComponent, !name.isEmpty { return name }
        return item.job.label
    }

    /// Something worth a person's attention about one job.
    ///
    /// Each says what was observed, not what it means: an unsigned agent is
    /// usually somebody's own script, and a missing program is usually an
    /// uninstall that forgot a file. Neither is malware by itself, and the
    /// interface says "check", never "threat".
    enum Concern: Equatable {
        /// The program is not there. launchd tries it at every login and
        /// logs a failure; nothing runs.
        case programMissing
        /// The program carries no signature at all.
        case unsigned
        /// The program's signature does not match it.
        case brokenSignature
        /// It runs a script through an interpreter, and the script is what
        /// matters; the interpreter's signature says nothing about it.
        case runsScript
    }

    /// What is worth saying about a job, given who signed its program.
    static func concerns(_ job: Job, signature: Signature) -> [Concern] {
        switch signature {
        case .missing:  return [.programMissing]
        case .unsigned: return [.unsigned]
        case .broken:   return [.brokenSignature]
        // Nothing known, so nothing to say: not a leftover, not a concern.
        case .unreadable: return []
        case .apple:
            let name = (job.program as NSString?)?.lastPathComponent ?? ""
            return interpreters.contains(name) && job.arguments.count > 1 ? [.runsScript] : []
        case .developer, .adHoc:
            return []
        }
    }

    /// One job, with what was found out about it.
    struct Assessed: Equatable {
        let job: Job
        let executable: URL?
        let signature: Signature
        let concerns: [Concern]
        /// The name on the signing certificate, for a developer-signed program.
        var signer: String?
        /// The app the job belongs to, for its name and icon.
        var app: URL?
    }

    /// Every job, assessed. Blocking -- each signature is a file read -- so
    /// call it off the main thread.
    static func assessAll(home: URL, appURL: (String) -> URL?) -> [Assessed] {
        jobs(home: home).map { assess($0, appURL: appURL) }
    }

    static func assess(_ job: Job, appURL: (String) -> URL?) -> Assessed {
        let executable = executable(of: job, appURL: appURL)
        let (signature, signer) = executable.map(inspect) ?? (.missing, nil)
        // An `SMAppService` job names its app outright; anything else is
        // known by where its program lives. Either can be a helper inside
        // the app a person installed -- Dropbox's names DropboxUpdater.app,
        // which is in Dropbox.app -- so both go to the outermost.
        let named = job.associatedBundleIDs.lazy.compactMap(appURL).first
        let app = (named ?? executable).flatMap(owningApp(of:)) ?? named
        return Assessed(job: job, executable: executable, signature: signature,
                        concerns: concerns(job, signature: signature),
                        signer: signer, app: app)
    }

    /// One plist read again from the disk, as it is now -- for the check
    /// before acting on it. An updater may have rewritten it since the list
    /// was read, to point at a program that is there.
    static func reassess(_ plist: URL, domain: Domain, appURL: (String) -> URL?) -> Assessed? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let job = parse(dict, at: plist, domain: domain) else { return nil }
        return assess(job, appURL: appURL)
    }
}
