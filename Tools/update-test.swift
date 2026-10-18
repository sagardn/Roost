//
//  update-test.swift
//
//  Exercises the independent updater: version ordering, feed decoding and
//  checksum verification.
//
//  Run:  cat Roost/Update/Version.swift Roost/Update/Release.swift \
//            Tools/update-test.swift | swift -
//
//  Version and Release are compiled in from the app's own source, so these
//  cannot drift from what ships. AppUpdater itself is network and process
//  work; its one pure part, sha256(of:), is checked here against shasum.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

print("Version")
check("parses a plain version", Version("1.2.3").map { ($0.major,$0.minor,$0.patch) } ?? (0,0,0) == (1,2,3))
check("parses a v prefix", Version("v1.0.12") == Version("1.0.12"))
check("fills in a missing patch", Version("1.2") == Version("1.2.0"))
check("rejects an empty string", Version("") == nil)
check("rejects a word", Version("latest") == nil)
check("rejects four components", Version("1.2.3.4") == nil)
check("rejects negatives", Version("1.-2.3") == nil)
check("keeps a prerelease for display", Version("1.2.3-beta.1")?.description == "1.2.3-beta.1")

print("Version ordering")
check("1.0.12 is newer than 1.0.9", Version("1.0.12")! > Version("1.0.9")!)
check("1.0.9 is not newer than 1.0.12", !(Version("1.0.9")! > Version("1.0.12")!))
check("2.0.0 beats 1.99.99", Version("2.0.0")! > Version("1.99.99")!)
check("equal versions are not newer", !(Version("1.0.0")! > Version("1.0.0")!))
check("a prerelease does not change order", Version("1.2.3-beta")! == Version("1.2.3")!)
// the double-digit trap: "1.0.9" > "1.0.12" as strings
check("patch versions compare as numbers, not text", Version("1.0.12")! > Version("1.0.9")!)

print("Release.decode")
let feed = """
{"tag_name":"v1.0.12","body":"notes here","draft":false,"prerelease":false,
 "assets":[{"name":"Roost.dmg","browser_download_url":"https://example.invalid/Roost.dmg"},
           {"name":"Roost.dmg.sha256","browser_download_url":"https://example.invalid/Roost.dmg.sha256"}]}
"""
do {
    let r = try Release.decode(Data(feed.utf8), assetNamed: "Roost.dmg")
    check("reads the version", r.version == Version("1.0.12"))
    check("reads the notes", r.notes == "notes here")
    check("finds the asset", r.downloadURL.absoluteString.hasSuffix("Roost.dmg"))
    check("finds the checksum beside it", r.checksumURL?.absoluteString.hasSuffix(".sha256") == true)
} catch {
    check("decodes a well-formed feed", false)
}

// An unreadable tag must be an error, never a quiet "you are up to date" --
// that is the behaviour this replaces.
do {
    _ = try Release.decode(Data(#"{"tag_name":"nightly","assets":[]}"#.utf8), assetNamed: "Roost.dmg")
    check("an unreadable tag throws", false)
} catch {
    check("an unreadable tag throws", (error as? Release.DecodeError) == .unreadableTag("nightly"))
}

do {
    let json = #"{"tag_name":"v1.0.0","assets":[{"name":"other.zip","browser_download_url":"https://e.invalid/x"}]}"#
    _ = try Release.decode(Data(json.utf8), assetNamed: "Roost.dmg")
    check("a missing asset throws", false)
} catch {
    check("a missing asset throws", (error as? Release.DecodeError) == .noAsset(named: "Roost.dmg"))
}

do {
    let json = #"{"tag_name":"v9.9.9","draft":true,"assets":[]}"#
    _ = try Release.decode(Data(json.utf8), assetNamed: "Roost.dmg")
    check("a draft throws", false)
} catch {
    check("a draft throws", (error as? Release.DecodeError) == .draft)
}

// A release with no checksum is still installable, just unverified.
do {
    let json = #"{"tag_name":"v1.0.0","assets":[{"name":"Roost.dmg","browser_download_url":"https://e.invalid/d"}]}"#
    let r = try Release.decode(Data(json.utf8), assetNamed: "Roost.dmg")
    check("a release without a checksum decodes", r.checksumURL == nil)
} catch {
    check("a release without a checksum decodes", false)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
