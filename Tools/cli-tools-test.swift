//
//  cli-tools-test.swift
//
//  Exercises how command-line tools are identified and what is claimed as
//  theirs.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift \
//            Roost/Cleanup/CommandLineTools.swift Tools/cli-tools-test.swift | swift -
//
//  A command-line tool has no bundle identifier, so every match here is a
//  name match -- which is exactly the loose matching the app uninstaller
//  refuses to tick for anybody. The cases below are therefore about two
//  things: that a shared directory is never claimed as one tool's, and that
//  a package name is never allowed to become a shell argument.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let home = URL(fileURLWithPath: "/Users/someone")

func candidates(_ name: String) -> [(URL, AppLeftovers.Confidence)] {
    CommandLineTools.leftoverCandidates(for: name, home: home)
}

func paths(_ name: String) -> [String] {
    candidates(name).map { $0.0.path }
}

// MARK: - The shared directories, which belong to everything

print("Shared directories are never one tool's")

// A tool called `config` would otherwise be offered ~/.config -- every
// other tool's settings, on a row with a checkbox.
for shared in ["config", "local", "cache", "ssh", "gnupg", "git", "bin"] {
    check("~/.\(shared) is not offered to a tool called \(shared)",
          !paths(shared).contains("/Users/someone/.\(shared)"))
}
check("a protected name is dropped entirely, not just its dot form",
      paths("config").isEmpty)
check("the protected list is matched without case",
      CommandLineTools.protectedNames.contains("ssh")
      && paths("SSH").isEmpty)

// MARK: - What is offered

print("\nWhere a tool's own files are looked for")

let ripgrep = paths("ripgrep")
check("the dot directory", ripgrep.contains("/Users/someone/.ripgrep"))
check("under ~/.config", ripgrep.contains("/Users/someone/.config/ripgrep"))
check("under ~/.cache", ripgrep.contains("/Users/someone/.cache/ripgrep"))
check("the XDG data directory",
      ripgrep.contains("/Users/someone/.local/share/ripgrep"))
check("Application Support",
      ripgrep.contains("/Users/someone/Library/Application Support/ripgrep"))
check("Library caches", ripgrep.contains("/Users/someone/Library/Caches/ripgrep"))
check("and the preferences plist",
      ripgrep.contains("/Users/someone/Library/Preferences/ripgrep.plist"))
check("nothing above the home folder is ever named",
      ripgrep.allSatisfy { $0.hasPrefix("/Users/someone/") })

print("\nConfidence")

check("an exact name match is likely, never certain",
      candidates("ripgrep").allSatisfy { $0.1 == .likely })
check("and so is never ticked for somebody",
      !AppLeftovers.isTickedByDefault(
          AppLeftovers.Item(url: URL(fileURLWithPath: "/Users/someone/.ripgrep"),
                            bytes: 0, confidence: .likely)))

// MARK: - The packaging suffix

print("\nThe shorter name a tool files its data under")

// The case this exists for: the Homebrew cask is `claude-code` and the
// settings are in ~/.claude, which no exact match finds.
check("claude-code also looks under claude",
      CommandLineTools.shortName(of: "claude-code") == "claude")
check("and it is offered at the lowest confidence",
      candidates("claude-code").contains {
          $0.0.path == "/Users/someone/.claude" && $0.1 == .possible
      })
check("-cli comes off", CommandLineTools.shortName(of: "eslint-cli") == "eslint")
check("a scoped npm package drops its scope",
      CommandLineTools.shortName(of: "@angular/cli") == "cli")
check("a name that is only a suffix is left alone",
      CommandLineTools.shortName(of: "-cli") == nil)
check("an ordinary name has no shorter form",
      CommandLineTools.shortName(of: "ripgrep") == nil)
check("a shortened name that is protected is still dropped",
      !paths("config-cli").contains("/Users/someone/.config"))

// MARK: - Settings files, not only settings directories

print("\nA tool's settings file beside its directory")

// The case this exists for: ~/.claude is 515 MB and ~/.claude.json sat next
// to it matched by nothing, because the search only looked for directories.
check("the JSON file beside the dot directory",
      paths("claude").contains("/Users/someone/.claude.json"))
check("a YAML one too", paths("tool").contains("/Users/someone/.tool.yaml"))
check("and a TOML one", paths("tool").contains("/Users/someone/.tool.toml"))
// The convention is .npmrc, not .npm.rc, so rc carries no dot of its own.
check("an rc file has no dot before it",
      paths("tool").contains("/Users/someone/.toolrc")
      && !paths("tool").contains("/Users/someone/.tool.rc"))
check("the dot directory is still offered",
      paths("tool").contains("/Users/someone/.tool"))

// A suffix can reach something shared that the bare name never would.
check("a tool called zsh is not offered .zshrc",
      !paths("zsh").contains("/Users/someone/.zshrc"))
check("nor is a tool called git offered .gitconfig",
      !paths("git").contains("/Users/someone/.gitconfig"))
check("the whole name is checked before the suffix is stripped",
      CommandLineTools.isProtected(URL(fileURLWithPath: "/Users/someone/.zshrc")))
check("a tool's own rc file is not protected by that",
      !CommandLineTools.isProtected(URL(fileURLWithPath: "/Users/someone/.toolrc")))
check("nor is its json",
      !CommandLineTools.isProtected(URL(fileURLWithPath: "/Users/someone/.claude.json")))

// MARK: - The command

print("\nThe removal command")

let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
let formula = CommandLineTools.Command(executable: brew,
                                       arguments: ["uninstall", "ripgrep"])
check("reads as somebody would type it", formula.text == "brew uninstall ripgrep")

// The reason the command is an executable and an array and not a string: a
// package name is somebody else's text, and npm will accept this one.
let nasty = CommandLineTools.Command(
    executable: URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
    arguments: ["uninstall", "-g", "; rm -rf ~"])
check("a package name stays one argument", nasty.arguments.count == 3)
check("and is never spliced into a command line",
      nasty.arguments[2] == "; rm -rf ~")

print("\nNode's own packages")

check("npm is not offered for removal by itself",
      CommandLineTools.nodeOwned.contains("npm"))
check("nor corepack", CommandLineTools.nodeOwned.contains("corepack"))

// MARK: - Where it looks

print("\nSearch locations")

let bins = CommandLineTools.binDirectories(home: home).map { $0.path }
check("~/.local/bin is searched", bins.contains("/Users/someone/.local/bin"))
check("go's bin is searched", bins.contains("/Users/someone/go/bin"))
// Homebrew's own bin is nothing but symlinks into Cellar, and the formulae
// are already listed. Offering both lets somebody remove the symlink and
// leave the formula.
check("Homebrew's bin is not, because its formulae are listed instead",
      !bins.contains("/opt/homebrew/bin") && !bins.contains("/usr/local/bin"))
check("both Homebrew prefixes are known",
      CommandLineTools.brewPrefixes.map { $0.path } == ["/opt/homebrew", "/usr/local"])

// MARK: - The receipt, against a real directory

print("\nWhat Homebrew was asked for")

// This Mac had 50 formulae in Cellar and 7 of them were typed by a person.
// Listing the other 43 buried the ones somebody recognises, and
// `brew uninstall brotli` would have refused anyway because curl needs it.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("roost-cli-test-\(getpid())")

func formula(_ name: String, receipt: String?) -> URL {
    let version = scratch.appendingPathComponent("\(name)/1.0.0")
    try? FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
    if let receipt {
        try? receipt.write(to: version.appendingPathComponent("INSTALL_RECEIPT.json"),
                           atomically: true, encoding: .utf8)
    }
    return scratch.appendingPathComponent(name)
}

check("a formula somebody asked for is offered",
      CommandLineTools.wasAskedFor(formula("gh", receipt: #"{"installed_on_request": true}"#)))
check("one pulled in as a dependency is not",
      !CommandLineTools.wasAskedFor(formula("brotli", receipt: #"{"installed_on_request": false}"#)))
// Not knowing is a reason to let somebody decide, not to hide it from them.
check("no receipt at all means it is still offered",
      CommandLineTools.wasAskedFor(formula("ancient", receipt: nil)))
check("an unreadable receipt means it is still offered",
      CommandLineTools.wasAskedFor(formula("broken", receipt: "{not json")))
check("a receipt without the field means it is still offered",
      CommandLineTools.wasAskedFor(formula("partial", receipt: #"{"source": {}}"#)))
check("an empty formula directory is offered",
      CommandLineTools.wasAskedFor(scratch.appendingPathComponent("nothing-here")))

// Two versions, the old one a dependency and the new one asked for: it was
// asked for.
let both = scratch.appendingPathComponent("twice")
for (version, asked) in [("1.0.0", "false"), ("2.0.0", "true")] {
    let directory = both.appendingPathComponent(version)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? #"{"installed_on_request": \#(asked)}"#
        .write(to: directory.appendingPathComponent("INSTALL_RECEIPT.json"),
               atomically: true, encoding: .utf8)
}
check("asked for in any kept version counts", CommandLineTools.wasAskedFor(both))

try? FileManager.default.removeItem(at: scratch)

print("")
if failures == 0 { print("all passed") } else { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
