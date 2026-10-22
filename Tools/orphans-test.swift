//
//  orphans-test.swift
//
//  Exercises which ~/Library entries are offered as the leftovers of apps
//  that are no longer installed.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift Roost/System/BackgroundItems.swift \
//            Roost/Cleanup/OrphanedData.swift Tools/orphans-test.swift | swift -
//
//  The uninstaller's suite asks what must not match a named app. This one
//  asks the harder version: what must not be called an orphan when nothing
//  names it at all. Every name below that is offered is a folder somebody's
//  data could be in, so most of the cases are refusals, and several are
//  names measured on a real Mac that a looser rule offered.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let nobody: (String) -> Bool = { _ in false }

// MARK: - Which names are identifiers

print("Identifiers")
check("a bundle identifier is one", OrphanedData.identifier(of: "com.maker.thing") == "com.maker.thing")
check("a preferences file is its identifier",
      OrphanedData.identifier(of: "com.maker.thing.plist") == "com.maker.thing")
check("a cookie store is its identifier",
      OrphanedData.identifier(of: "com.maker.thing.binarycookies") == "com.maker.thing")
// The uninstaller's lesson, again: `.helper` is a child identifier, and
// stripping it as an extension would make the helper's data the app's.
check("a child identifier keeps its last component",
      OrphanedData.identifier(of: "com.maker.thing.helper") == "com.maker.thing.helper")
check("two components is a vendor, not an app", OrphanedData.identifier(of: "com.google") == nil)
check("a plain folder name is not one", OrphanedData.identifier(of: "Google") == nil)
check("a name with spaces is not one", OrphanedData.identifier(of: "My App.Support.files") == nil)
check("a dotfile is not one", OrphanedData.identifier(of: ".GlobalPreferences.plist") == nil)
check("an empty component is not one", OrphanedData.identifier(of: "com..thing") == nil)
check("a dated backup is not one", OrphanedData.identifier(of: "2024.backup.old") == nil)
check("hyphens and underscores are allowed",
      OrphanedData.identifier(of: "org.some-maker.my_app") == "org.some-maker.my_app")

// MARK: - What is never offered

print("Readable names")
let readable: [(String, String)] = [
    ("com.getdropbox.DropboxMetaInstaller", "Dropbox Meta Installer"),
    ("com.vercel.cli", "Vercel CLI"),
    ("com.acme.helper", "Acme Helper"),
    ("org.videolan.vlc", "Videolan VLC"),
    ("com.example.my-tool_name", "My tool name"),
    ("com.acme.HTTPServer", "HTTP Server"),
    ("com.spotify.client", "Spotify Client"),
    ("com.adobe.Acrobat.Pro", "Acrobat Pro"),
    ("com.maker.app", "Maker App")
]
for (id, name) in readable {
    check("\(id) reads as \(name)", OrphanedData.readableName(of: id) == name)
}

print("Excluded")
check("Apple's own", OrphanedData.isExcluded("com.apple.Safari"))
check("Apple's, in another case", OrphanedData.isExcluded("COM.APPLE.dt.Xcode"))
// Measured: this was on the list until the rule looked inside the prefix.
check("Apple's, behind a prefix", OrphanedData.isExcluded("systemgroup.com.apple.icloud.searchpartyd.sharedsettings"))
check("an app group", OrphanedData.isExcluded("group.com.maker.shared"))
// Measured: a team-ID prefixed group preferences file.
check("a team-ID group", OrphanedData.isExcluded("RP2S87B72W.com.sagar.perch.widgets"))
check("Roost's own", OrphanedData.isExcluded("com.sagar.roost"))
check("Perch's, which FormerName carries across", OrphanedData.isExcluded("com.sagar.perch.Widgets"))
check("an ordinary maker is not excluded", !OrphanedData.isExcluded("com.maker.thing"))
// Ten characters, all upper-case letters, no digit: a word, not a team.
check("an upper-case word is not a team ID", !OrphanedData.isExcluded("COMPANYABC.thing.app"))
check("a team ID needs a digit", !OrphanedData.isExcluded("ABCDEFGHIJ.thing.app"))

// MARK: - Who claims an identifier

print("Claims")
let known: Set<String> = ["com.maker.thing", "com.microsoft.word", "org.tool.agent"]
check("an installed app claims its own data",
      OrphanedData.isClaimed("com.maker.thing", known: known, lookup: nobody))
check("claims are case-insensitive",
      OrphanedData.isClaimed("COM.Maker.Thing", known: known, lookup: nobody))
check("an installed app claims its helper's data",
      OrphanedData.isClaimed("com.maker.thing.helper", known: known, lookup: nobody))
check("an installed app claims the identifier it is a child of",
      OrphanedData.isClaimed("com.maker.suite", known: ["com.maker.suite.writer"], lookup: nobody))
// Word is not a child of `com.microsoft.office`, so the suite's shared folder
// is not *claimed* -- but it shares a maker with something installed, which
// is what keeps it from being ticked (checked under "Same maker").
check("a sibling's folder is not claimed by the rule for children",
      !OrphanedData.isClaimed("com.microsoft.office", known: known, lookup: nobody))
check("a launchd job claims its label's data",
      OrphanedData.isClaimed("org.tool.agent", known: known, lookup: nobody))
check("a prefix that is not a child does not claim",
      !OrphanedData.isClaimed("com.maker.thingelse", known: known, lookup: nobody))
check("an unrelated identifier is unclaimed",
      !OrphanedData.isClaimed("com.gone.app", known: known, lookup: nobody))
check("LaunchServices claims what it knows",
      OrphanedData.isClaimed("com.elsewhere.app", known: [], lookup: { $0 == "com.elsewhere.app" }))
check("LaunchServices is asked about the parent too",
      OrphanedData.isClaimed("com.elsewhere.app.helper", known: [],
                             lookup: { $0 == "com.elsewhere.app" }))
var asked: [String] = []
_ = OrphanedData.isClaimed("com.a.b.c", known: [], lookup: { asked.append($0); return false })
check("LaunchServices is never asked about a bare vendor", !asked.contains("com.a"))

print("Same maker")
check("a sibling of something installed shares a maker",
      OrphanedData.sharesMaker("com.maker.installer", known: known))
check("a suite's shared folder shares a maker with the suite's apps",
      OrphanedData.sharesMaker("com.microsoft.office", known: known))
check("a different maker does not", !OrphanedData.sharesMaker("com.other.installer", known: known))

// MARK: - On a disk

print("Finding")
let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent("orphans-test-\(UUID().uuidString)")
func make(_ path: String, bytes: Int = 4096) {
    let url = home.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
}
make("Library/Caches/com.gone.app/data.bin", bytes: 300_000)
make("Library/Caches/com.maker.thing/data.bin")
make("Library/Caches/com.maker.oldinstaller/data.bin")
make("Library/Caches/com.apple.Safari/data.bin")
make("Library/Logs/com.gone.app/run.log")
make("Library/Application Support/com.vercel.cli/auth.json")
make("Library/Application Support/Notes/notes.db")
make("Library/Preferences/com.gone.app.plist")
make("Library/Preferences/group.com.gone.shared.plist")
make("Library/Containers/com.gone.app/Data/x")

let found = OrphanedData.find(home: home, known: known, lookup: nobody)
let names = Set(found.map { $0.place.rawValue + "/" + $0.name })
check("a cache nobody claims is found", names.contains("caches/com.gone.app"))
check("its logs are found", names.contains("logs/com.gone.app"))
check("its preferences are found", names.contains("preferences/com.gone.app.plist"))
check("an installed app's cache is not", !names.contains("caches/com.maker.thing"))
check("Apple's cache is not", !names.contains("caches/com.apple.Safari"))
check("a folder named by a word is not", !names.contains("applicationSupport/Notes"))
check("an app group is not", !names.contains("preferences/group.com.gone.shared.plist"))
check("Containers are not searched", !found.contains { $0.url.path.contains("/Containers/") })
check("biggest first", found.first?.name == "com.gone.app" && found.first?.place == .caches)
check("its size is measured", (found.first?.bytes ?? 0) >= 300_000 && found.first?.isMeasured == true)

print("Ticking")
func entry(_ place: OrphanedData.Place, _ name: String) -> OrphanedData.Item? {
    found.first { $0.place == place && $0.name == name }
}
check("an unclaimed cache is ticked",
      entry(.caches, "com.gone.app").map { OrphanedData.isTicked($0, known: known) } == true)
check("unclaimed logs are ticked",
      entry(.logs, "com.gone.app").map { OrphanedData.isTicked($0, known: known) } == true)
// The case this whole split exists for: a tool's sign-in, which nothing
// re-creates and no installed app will ever claim.
check("a command-line tool's data is offered but never ticked",
      entry(.applicationSupport, "com.vercel.cli").map { !OrphanedData.isTicked($0, known: known) } == true)
check("preferences are never ticked",
      entry(.preferences, "com.gone.app.plist").map { !OrphanedData.isTicked($0, known: known) } == true)
check("a cache from the same maker as something installed is not ticked",
      entry(.caches, "com.maker.oldinstaller").map { !OrphanedData.isTicked($0, known: known) } == true)

print("Checked again before the Bin")
let gone = home.appendingPathComponent("Library/Caches/com.gone.app")
check("still an orphan", OrphanedData.isStillOrphaned(gone, home: home, known: known, lookup: nobody))
check("not once the app is reinstalled",
      !OrphanedData.isStillOrphaned(gone, home: home, known: known.union(["com.gone.app"]), lookup: nobody))
check("not once LaunchServices knows it",
      !OrphanedData.isStillOrphaned(gone, home: home, known: known, lookup: { $0 == "com.gone.app" }))
check("not outside the searched folders",
      !OrphanedData.isStillOrphaned(home.appendingPathComponent("Documents/com.gone.app"),
                                    home: home, known: known, lookup: nobody))
check("not one level down",
      !OrphanedData.isStillOrphaned(gone.appendingPathComponent("data.bin"),
                                    home: home, known: known, lookup: nobody))
check("not once it has gone",
      !OrphanedData.isStillOrphaned(home.appendingPathComponent("Library/Caches/com.never.was"),
                                    home: home, known: known, lookup: nobody))
// A symlink in place of the entry must not lead the Bin somewhere else.
make("Documents/precious/photos.bin", bytes: 2_000_000)
let link = home.appendingPathComponent("Library/Caches/com.linked.app")
try? fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("Documents/precious"))
check("a symlink is judged where it is, and its parent is still the root",
      OrphanedData.isStillOrphaned(link, home: home, known: known, lookup: nobody))
// Measured as a link: the 2 MB it points at is not in Caches, and a row
// claiming it was would be a row offering somebody's Documents.
let linked = OrphanedData.find(home: home, known: known, lookup: nobody).first { $0.url == link }
check("a symlink is not measured as what it points at", (linked?.bytes ?? 0) < 1_000_000)

try? fm.removeItem(at: home)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
