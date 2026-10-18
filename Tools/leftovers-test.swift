//
//  leftovers-test.swift
//
//  Exercises which files an uninstaller claims belong to an app.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift Tools/leftovers-test.swift | swift -
//
//  This is the file where a mistake deletes somebody else's data. The removal
//  itself is one call; deciding what to remove is the part that goes wrong,
//  and it goes wrong silently -- a folder taken for an app's leftovers is not
//  missed until the data in it is wanted. So the cases below are mostly about
//  what must NOT match.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func match(_ filename: String, id: String = "com.maker.thing",
           name: String = "Thing") -> AppLeftovers.Confidence? {
    AppLeftovers.match(filename: filename, bundleID: id, appName: name)
}

// MARK: - The identifier, which is unique by construction

print("AppLeftovers.match — by identifier")

check("the identifier itself", match("com.maker.thing") == .certain)
check("with a plist extension", match("com.maker.thing.plist") == .certain)
check("with a savedState extension", match("com.maker.thing.savedState") == .certain)
check("a helper under it is likely, not certain",
      match("com.maker.thing.helper") == .likely)
check("and a deeper one too", match("com.maker.thing.helper.renderer.plist") == .likely)
// The bug this pair exists for: deletingPathExtension treats ".helper" as a
// file extension, which made a helper's data read as the app's own and tick
// itself. Only known file suffixes are stripped now.
check("an unknown suffix is part of the identifier, not an extension",
      match("com.maker.thing.renderer") == .likely)
check("while a known one is stripped", match("com.maker.thing.log") == .certain)
check("and a known one on a child still reads as a child",
      match("com.maker.thing.helper.log") == .likely)

// MARK: - What must not match

print("\nAppLeftovers.match — what it refuses")

// The dot is the whole safeguard: without it, uninstalling "thing" would
// take "thingelse" with it.
check("an identifier that merely starts the same is not a child",
      match("com.maker.thingelse") == nil)
check("nor one that starts the same with a plist",
      match("com.maker.thingelse.plist") == nil)
check("a different maker entirely", match("com.other.thing") == nil)
check("an unrelated file", match("com.apple.finder.plist") == nil)
check("something containing the name is not the name",
      match("ThingManager") == nil)
check("nor a name with a suffix", match("Thing Pro") == nil)
check("nor one with a prefix", match("My Thing") == nil)
check("an empty filename matches nothing", match("") == nil)

// MARK: - The name, which is a guess

print("\nAppLeftovers.match — by name")

check("the app's exact name is possible, no better", match("Thing") == .possible)
check("case does not matter for a name", match("thing") == .possible)
check("and the folder keeps that low confidence even with an extension",
      match("Thing.log") == .possible)

// An app with no identifier -- a CLI tool, a drag-installed binary -- can
// only be matched by name, and that is still only a guess.
check("with no identifier, the name is all there is",
      match("Thing", id: "") == .possible)
check("and a wrong name still matches nothing",
      match("Other", id: "") == nil)
check("with neither identifier nor name, nothing matches",
      match("anything", id: "", name: "") == nil)

// MARK: - What is ticked without being asked

print("\nAppLeftovers.isTickedByDefault")

func item(_ confidence: AppLeftovers.Confidence) -> AppLeftovers.Item {
    AppLeftovers.Item(url: URL(fileURLWithPath: "/x"), bytes: 1, confidence: confidence)
}

// The default selection is what somebody will press the button on without
// reading every row, so only what cannot belong to anything else is in it.
check("certain is ticked", AppLeftovers.isTickedByDefault(item(.certain)))
check("likely is not", !AppLeftovers.isTickedByDefault(item(.likely)))
check("and a name match certainly is not",
      !AppLeftovers.isTickedByDefault(item(.possible)))

print("\nConfidence ordering")

check("certain outranks likely", AppLeftovers.Confidence.certain > .likely)
check("likely outranks possible", AppLeftovers.Confidence.likely > .possible)

// MARK: - Where it looks

print("\nAppLeftovers.searchRoots")

do {
    let roots = AppLeftovers.searchRoots(home: URL(fileURLWithPath: "/Users/me"))
    check("every root is under the user's Library",
          roots.allSatisfy { $0.path.hasPrefix("/Users/me/Library/") })
    check("Preferences is among them",
          roots.contains { $0.lastPathComponent == "Preferences" })
    check("Containers too", roots.contains { $0.lastPathComponent == "Containers" })
    // Both need Full Disk Access, so including them would mean a row that is
    // always empty and reads as "this app left nothing there".
    check("Saved Application State is not, because it cannot be read",
          !roots.contains { $0.lastPathComponent == "Saved Application State" })
    check("nor Cookies", !roots.contains { $0.lastPathComponent == "Cookies" })
    check("and nothing outside home",
          roots.allSatisfy { !$0.path.hasPrefix("/System") && !$0.path.hasPrefix("/Library") })
}

// MARK: - Finding them in a home built for the purpose

print("\nAppLeftovers.find")

do {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("roost-home-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }

    func place(_ path: String, bytes: Int = 1_000) {
        let url = home.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: url)
    }

    place("Library/Preferences/com.maker.thing.plist", bytes: 2_000)
    place("Library/Application Support/com.maker.thing/data.db", bytes: 5_000)
    place("Library/Caches/com.maker.thing.helper/blob", bytes: 3_000)
    place("Library/Logs/Thing/run.log", bytes: 1_000)
    // Must not be taken: a different app whose identifier starts the same.
    place("Library/Preferences/com.maker.thingelse.plist", bytes: 9_000)
    // Must not be taken: somebody else entirely.
    place("Library/Preferences/com.apple.finder.plist", bytes: 9_000)

    let found = AppLeftovers.find(bundleID: "com.maker.thing", appName: "Thing", home: home)
    let names = found.map(\.name)

    check("the preference file is found", names.contains("com.maker.thing.plist"))
    check("the support folder is found", names.contains("com.maker.thing"))
    check("the helper's cache is found", names.contains("com.maker.thing.helper"))
    check("the log folder is found by name", names.contains("Thing"))

    check("a similarly named app is left alone",
          !names.contains("com.maker.thingelse.plist"))
    check("and an unrelated app certainly is",
          !names.contains("com.apple.finder.plist"))

    check("the support folder's size is what is inside it",
          (found.first { $0.name == "com.maker.thing" }?.bytes ?? 0) >= 5_000)
    check("certain items come before guesses",
          found.first?.confidence == .certain && found.last?.confidence == .possible)
    check("only the certain ones are ticked to begin with",
          found.filter(AppLeftovers.isTickedByDefault).allSatisfy { $0.confidence == .certain })

    // An app bundle, when one was given.
    let bundle = home.appendingPathComponent("Thing.app")
    try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    let withBundle = AppLeftovers.find(bundleID: "com.maker.thing", appName: "Thing",
                                       home: home, includingBundle: bundle)
    check("the app itself is included when given",
          withBundle.contains { $0.name == "Thing.app" })
    check("and it is certain", withBundle.first { $0.name == "Thing.app" }?.confidence == .certain)

    check("an app that left nothing finds nothing",
          AppLeftovers.find(bundleID: "com.nobody.absent", appName: "Absent", home: home).isEmpty)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
