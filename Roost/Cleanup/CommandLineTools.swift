import Foundation

/// Command-line tools somebody has installed, and how to take them away
/// again.
///
/// Apps announce themselves: a bundle in `/Applications` with an identifier
/// inside it. Command-line tools do not. They are a binary somewhere on
/// `PATH`, and the only record of where they came from is the layout of the
/// directory holding them. So discovery here reads those directories
/// directly rather than asking `brew list` or `npm ls -g`:
///
///   - no subprocess per listing, so the window fills in milliseconds;
///   - no dependence on `PATH`, which an app launched from Finder does not
///     inherit from anybody's shell;
///   - a package manager that is installed but broken still has its
///     packages found.
///
/// Removal splits in two, and the split is the important decision. A tool a
/// package manager installed is removed by **that manager's own command** --
/// deleting `Cellar/ripgrep` behind Homebrew's back leaves its receipts
/// claiming the formula is still there and its symlinks dangling. A tool
/// that is just a file somebody downloaded has no manager, so it goes to the
/// Bin like anything else Roost removes.
enum CommandLineTools {

    enum Kind {
        /// `Cellar/<name>/<version>` -- `brew uninstall`.
        case brewFormula
        /// `Caskroom/<name>/<version>` -- `brew uninstall --cask`.
        case brewCask
        /// `<prefix>/lib/node_modules/<name>` -- `npm uninstall -g`.
        case npmGlobal
        /// `~/.local/pipx/venvs/<name>` -- `pipx uninstall`.
        case pipxApp
        /// An executable file in a bin directory, owned by nobody.
        case loose
        /// A symlink in a bin directory pointing at an installation
        /// elsewhere -- the kind an installer script leaves.
        case link

        var label: String {
            switch self {
            case .brewFormula: return "Homebrew"
            case .brewCask:    return "Homebrew cask"
            case .npmGlobal:   return "npm"
            case .pipxApp:     return "pipx"
            case .loose:       return localized("downloaded")
            case .link:        return localized("linked")
            }
        }

        /// How it got here, in words for somebody who has never typed
        /// `brew`: the manager's name alone ("pipx", "linked") said nothing
        /// to them.
        var source: String {
            switch self {
            case .brewFormula: return localized("Installed with Homebrew")
            case .brewCask:    return localized("App installed with Homebrew")
            case .npmGlobal:   return localized("Installed with npm (Node.js)")
            case .pipxApp:     return localized("Installed with pipx (Python)")
            case .loose:       return localized("Installed by hand")
            case .link:        return localized("Shortcut to a program elsewhere")
            }
        }
    }

    /// The command that removes a managed tool.
    ///
    /// Held as an executable and an argument array, never a string to hand a
    /// shell. A package called `; rm -rf ~` is a legal npm name.
    struct Command: Equatable {
        let executable: URL
        let arguments: [String]

        /// What to show somebody before they agree to it.
        var text: String {
            ([executable.lastPathComponent] + arguments).joined(separator: " ")
        }
    }

    struct Tool: Equatable {
        let name: String
        let kind: Kind
        /// The directory or file that *is* the installation.
        let location: URL
        let bytes: Int64
        /// A version, or what a link points at.
        let detail: String?
        /// nil for a tool no manager owns -- those go to the Bin instead.
        let command: Command?

        var isManaged: Bool { command != nil }

        static func == (a: Tool, b: Tool) -> Bool {
            a.name == b.name && a.location == b.location
        }
    }

    // MARK: - Where things live

    /// Both Homebrew prefixes. Apple silicon uses the first and Intel the
    /// second, and a Mac that has been migrated between them has both.
    static let brewPrefixes = [URL(fileURLWithPath: "/opt/homebrew"),
                               URL(fileURLWithPath: "/usr/local")]

    /// Directories a loose binary gets dropped into.
    ///
    /// `/opt/homebrew/bin` and `/usr/local/bin` are not here. They are almost
    /// entirely Homebrew's own symlinks into `Cellar`, which are listed as
    /// formulae already, and offering the same tool twice under two names is
    /// how somebody removes the symlink and leaves the formula.
    static func binDirectories(home: URL) -> [URL] {
        [".local/bin", "bin", "go/bin", ".cargo/bin", ".bun/bin"]
            .map { home.appendingPathComponent($0) }
    }

    // MARK: - Discovery

    /// Everything installed, newest layout first.
    ///
    /// Blocking -- it stats a few thousand files. Call it off the main
    /// thread.
    static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [Tool] {
        var tools = brewTools()
        tools += npmTools(home: home)
        tools += pipxTools(home: home)
        tools += binTools(home: home)
        return tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func brewTools() -> [Tool] {
        let fm = FileManager.default
        var tools: [Tool] = []

        for prefix in brewPrefixes {
            let brew = prefix.appendingPathComponent("bin/brew")
            guard fm.isExecutableFile(atPath: brew.path) else { continue }

            for (folder, kind, extra) in [("Cellar", Kind.brewFormula, [String]()),
                                          ("Caskroom", Kind.brewCask, ["--cask"])] {
                let root = prefix.appendingPathComponent(folder)
                for name in children(of: root) {
                    let location = root.appendingPathComponent(name)
                    guard wasAskedFor(location) else { continue }
                    tools.append(Tool(
                        name: name, kind: kind, location: location,
                        bytes: installedBytes(at: location, fm: fm),
                        detail: versionText(in: location),
                        command: Command(executable: brew,
                                         arguments: ["uninstall"] + extra + [name])))
                }
            }
        }
        return tools
    }

    /// What the install actually weighs.
    ///
    /// A cask for an app does not hold the app: `Caskroom/hammerspoon/1.1.1`
    /// holds a symlink to `/Applications/Hammerspoon.app`, so measuring the
    /// directory reported twelve kilobytes for a hundred-megabyte app. The
    /// links are resolved before measuring. A cask that ships a binary
    /// rather than an app has the real file there and is unaffected.
    private static func installedBytes(at location: URL, fm: FileManager) -> Int64 {
        let direct = AppLeftovers.size(of: location, fm: fm)
        guard direct < 1_000_000 else { return direct }

        var total: Int64 = 0
        for version in children(of: location) {
            let versionDirectory = location.appendingPathComponent(version)
            for entry in children(of: versionDirectory) {
                total += AppLeftovers.size(
                    of: versionDirectory.appendingPathComponent(entry).resolvingSymlinksInPath(),
                    fm: fm)
            }
        }
        return max(total, direct)
    }

    /// Whether somebody asked for this formula, or Homebrew pulled it in.
    ///
    /// This Mac has 50 formulae in `Cellar` and seven of them were typed by
    /// a person; the other 43 are dependencies -- `brotli`, `c-ares`,
    /// `abseil`. Listing all of them buries the ones somebody recognises,
    /// and `brew uninstall brotli` would refuse anyway because `curl` needs
    /// it. So the receipt Homebrew writes beside each install is read, and
    /// only `installed_on_request` is offered. `brew autoremove` is what
    /// clears the rest, once nothing wants them.
    ///
    /// A missing receipt means it is shown. A cask has none, and so does an
    /// install old enough to predate them; not knowing is a reason to let
    /// somebody decide, not to hide it from them.
    static func wasAskedFor(_ location: URL) -> Bool {
        let versions = children(of: location)
        guard !versions.isEmpty else { return true }
        for version in versions {
            let receipt = location.appendingPathComponent(version)
                .appendingPathComponent("INSTALL_RECEIPT.json")
            guard let data = try? Data(contentsOf: receipt),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let asked = json["installed_on_request"] as? Bool
            else { return true }
            if asked { return true }
        }
        return false
    }

    /// Globally installed npm packages.
    ///
    /// Scoped packages are two levels deep -- `@scope/name` is a directory
    /// called `@scope` holding one called `name` -- so a `@` entry is
    /// descended into rather than listed.
    private static func npmTools(home: URL) -> [Tool] {
        let fm = FileManager.default
        var tools: [Tool] = []

        let prefixes = brewPrefixes + [home.appendingPathComponent(".npm-global"),
                                       home.appendingPathComponent(".bun/install/global")]
        for prefix in prefixes {
            let npm = prefix.appendingPathComponent("bin/npm")
            guard fm.isExecutableFile(atPath: npm.path) else { continue }
            let root = prefix.appendingPathComponent("lib/node_modules")

            var names: [String] = []
            for entry in children(of: root) {
                if entry.hasPrefix("@") {
                    names += children(of: root.appendingPathComponent(entry))
                        .map { "\(entry)/\($0)" }
                } else {
                    names.append(entry)
                }
            }

            for name in names where !nodeOwned.contains(name) {
                let location = root.appendingPathComponent(name)
                tools.append(Tool(
                    name: name, kind: .npmGlobal, location: location,
                    bytes: AppLeftovers.size(of: location, fm: fm),
                    detail: packageVersion(in: location),
                    command: Command(executable: npm,
                                     arguments: ["uninstall", "-g", name])))
            }
        }
        return tools
    }

    /// Shipped as part of Node, not installed by anybody.
    ///
    /// They sit in the same `node_modules` as everything `npm -g` installs
    /// and are indistinguishable from it by layout. `npm uninstall -g npm`
    /// is a request to remove the thing being asked to do the removing.
    static let nodeOwned: Set<String> = ["npm", "corepack"]

    private static func pipxTools(home: URL) -> [Tool] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".local/pipx/venvs")
        let pipx = home.appendingPathComponent(".local/bin/pipx")
        guard fm.isExecutableFile(atPath: pipx.path) else { return [] }

        return children(of: root).map { name in
            let location = root.appendingPathComponent(name)
            return Tool(name: name, kind: .pipxApp, location: location,
                        bytes: AppLeftovers.size(of: location, fm: fm),
                        detail: nil,
                        command: Command(executable: pipx,
                                         arguments: ["uninstall", name]))
        }
    }

    /// Executables and links sitting in the bin directories, owned by no
    /// manager. These are the ones that go to the Bin.
    private static func binTools(home: URL) -> [Tool] {
        let fm = FileManager.default
        var tools: [Tool] = []

        for folder in binDirectories(home: home) {
            for name in children(of: folder) {
                let url = folder.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey,
                                                               .isExecutableKey,
                                                               .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                    // What the link points at, not the link, which is a few
                    // bytes. The install it belongs to is usually larger
                    // still and turns up as a leftover under its own name.
                    tools.append(Tool(name: name, kind: .link, location: url,
                                      bytes: AppLeftovers.size(of: url.resolvingSymlinksInPath(),
                                                               fm: fm),
                                      detail: target, command: nil))
                } else if values?.isExecutable == true, values?.isDirectory != true {
                    tools.append(Tool(name: name, kind: .loose, location: url,
                                      bytes: AppLeftovers.size(of: url, fm: fm),
                                      detail: nil, command: nil))
                }
            }
        }
        return tools
    }

    /// Visible children only. A `.metadata` directory sits beside the
    /// versions in `Caskroom` and is not a cask.
    private static func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// The version directory under a formula or cask, or how many there are
    /// when an old one has been kept.
    private static func versionText(in location: URL) -> String? {
        let versions = children(of: location)
        if versions.count > 1 { return localized("%0 versions", String(versions.count)) }
        return versions.first
    }

    private static func packageVersion(in location: URL) -> String? {
        guard let data = try? Data(contentsOf: location.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }
}

// MARK: - What a tool leaves behind

extension CommandLineTools {

    /// Directories that belong to the system or to everything at once, and
    /// are never a tool's own leftovers however well the name matches.
    ///
    /// `~/.config` and `~/.local` hold every tool's settings; `~/.cache` the
    /// same for caches; `~/.ssh` and `~/.gnupg` hold keys. A tool happening
    /// to be called `config` must not put any of them on a list with a
    /// checkbox next to it.
    static let protectedNames: Set<String> = [
        "config", "local", "cache", "bin", "share", "ssh", "gnupg", "gpg",
        "git", "gitconfig", "gitignore", "profile", "zshrc", "bashrc",
        "bash_profile", "zprofile", "zsh_history", "bash_history", "trash",
        "library", "documents", "desktop", "downloads", "applications",
        "icloud", "keychains"
    ]

    /// The shapes a settings file in the home folder takes.
    ///
    /// `rc` carries no dot of its own -- the convention is `.npmrc`, not
    /// `.npm.rc`.
    static let configSuffixes = [".json", ".yaml", ".yml", ".toml", ".conf",
                                 ".ini", ".cfg", "rc"]

    /// Whether this path is one of the shared ones, however it was reached.
    ///
    /// Both forms are checked, and the order matters. `.zshrc` is protected
    /// under its whole name; stripping `rc` first leaves `zsh`, which is not
    /// on the list, and a tool called `zsh` would have been offered
    /// somebody's shell configuration.
    static func isProtected(_ url: URL) -> Bool {
        var name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
        if protectedNames.contains(name) { return true }
        for suffix in configSuffixes where name.hasSuffix(suffix) && name.count > suffix.count {
            return protectedNames.contains(String(name.dropLast(suffix.count)))
        }
        return false
    }

    /// Suffixes a tool's command name carries that its data directory does
    /// not. A cask called `something-code` keeps its settings in
    /// `~/.something`, which no exact-name match will ever find.
    static let packagingSuffixes = ["-cli", "-code", "-bin", "-app", "-tool"]

    /// The shorter name a tool's data might be filed under, if there is one.
    static func shortName(of name: String) -> String? {
        // A scoped npm package is filed under its own name, not its scope.
        let bare = name.contains("/") ? String(name.split(separator: "/").last!) : name
        for suffix in packagingSuffixes where bare.hasSuffix(suffix) && bare.count > suffix.count {
            return String(bare.dropLast(suffix.count))
        }
        return bare == name ? nil : bare
    }

    /// Where a command-line tool keeps things, as name templates.
    ///
    /// Both conventions, because tools follow both: the Unix dot-directory
    /// in the home folder or under `~/.config`, and the macOS one under
    /// `~/Library`. A tool that has been ported usually has files in each.
    static func leftoverCandidates(for name: String, home: URL) -> [(URL, AppLeftovers.Confidence)] {
        var candidates: [(URL, AppLeftovers.Confidence)] = []

        // The exact name is still only a name -- nothing here is ever
        // `certain`, which is why none of it is ticked for somebody.
        func add(_ name: String, _ confidence: AppLeftovers.Confidence) {
            guard !protectedNames.contains(name.lowercased()) else { return }
            var relative = [".\(name)", ".config/\(name)", ".cache/\(name)",
                            ".local/share/\(name)", ".local/state/\(name)",
                            "Library/Application Support/\(name)",
                            "Library/Caches/\(name)", "Library/Logs/\(name)",
                            "Library/Preferences/\(name).plist"]

            // A dot *file*, not only a dot directory. Half the tools that
            // keep a directory in the home folder keep a settings file
            // beside it -- ~/.claude is 515 MB here and ~/.claude.json sat
            // next to it, matched by nothing, because the search only ever
            // looked for directories.
            relative += configSuffixes.map { ".\(name)\($0)" }

            candidates += relative
                .map { (home.appendingPathComponent($0), confidence) }
                // A suffixed name can land on something shared that the bare
                // name never would: a tool called `zsh` reaching `.zshrc`.
                .filter { !isProtected($0.0) }
        }

        add(name, .likely)
        if let short = shortName(of: name) { add(short, .possible) }
        return candidates
    }

    /// The tool's own installation, plus everything on disk that matches its
    /// name. Blocking.
    static func leftovers(for tool: Tool,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [AppLeftovers.Item] {
        let fm = FileManager.default
        var found: [AppLeftovers.Item] = []

        // A managed tool's own files are the manager's to remove, so they
        // are not offered as something to put in the Bin. An unmanaged one's
        // are the whole point.
        if !tool.isManaged, fm.fileExists(atPath: tool.location.path) {
            // A link is listed at its target's size, which is what the tool
            // takes -- but only the link goes to the Bin, so this row is the
            // link's own size. Otherwise removing `~/.local/bin/claude` said
            // it freed hundreds of megabytes, and freed a few bytes.
            // `attributesOfItem` does not follow the link.
            let bytes = tool.kind == .link
                ? ((try? fm.attributesOfItem(atPath: tool.location.path))?[.size] as? NSNumber)?.int64Value ?? 0
                : tool.bytes
            found.append(AppLeftovers.Item(url: tool.location,
                                           bytes: bytes,
                                           confidence: .certain))
        }

        var seen: Set<URL> = Set(found.map(\.url))
        for (url, confidence) in leftoverCandidates(for: tool.name, home: home) {
            guard !seen.contains(url), fm.fileExists(atPath: url.path) else { continue }
            seen.insert(url)
            found.append(AppLeftovers.Item(url: url,
                                           bytes: AppLeftovers.size(of: url, fm: fm),
                                           confidence: confidence))
        }

        return found.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence
                                           : $0.bytes > $1.bytes
        }
    }
}

// MARK: - Running the manager's command

extension CommandLineTools {

    struct Result {
        let command: String
        let status: Int32
        let output: String

        var succeeded: Bool { status == 0 }
    }

    /// Runs a removal command and hands back what it said.
    ///
    /// `Process` with an argument array, never a shell: the package name is
    /// somebody else's string and the only reason it is safe to pass along
    /// is that nothing ever parses it.
    ///
    /// `PATH` is set explicitly. An app launched from Finder inherits a
    /// `PATH` of four system directories, and Homebrew shells out to `git`
    /// and `curl` from its own prefix during an uninstall.
    static func run(_ command: Command,
                    completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments

            let prefix = command.executable.deletingLastPathComponent().path
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(prefix):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            // Homebrew asks before anything it considers destructive unless
            // told it is not at a terminal, and there is nobody here to
            // answer it.
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["NONINTERACTIVE"] = "1"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Read to the end while it runs, then wait. A pipe's buffer is
            // 64 KB and a brew uninstall that fills it blocks for ever waiting
            // for somebody to read, which looks exactly like a hang. It was
            // read by a readability handler, appending on its own queue to
            // the same `Data` this thread appended the tail to after setting
            // the handler to nil -- which does not wait for a call already
            // running. Two threads writing one buffer, and the tail, where
            // brew says why it refused, could be lost.
            let data: Data
            let status: Int32
            do {
                try process.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
            } catch {
                DispatchQueue.main.async {
                    completion(Result(command: command.text, status: -1,
                                      output: error.localizedDescription))
                }
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(Result(command: command.text, status: status,
                                  output: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
