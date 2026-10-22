//
//  downloads-test.swift
//
//  Exercises what in Downloads is offered as finished with: installers and
//  downloads that never completed.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/AppLeftovers.swift Roost/Cleanup/StaleDownloads.swift \
//            Tools/downloads-test.swift | swift -
//
//  The two ways this goes wrong are both about time: a partial download that
//  is still arriving, and a file that changed between the scan and the click.
//  Both are arranged here with dates set by hand.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func kind(_ name: String) -> StaleDownloads.Kind? {
    StaleDownloads.kind(of: URL(fileURLWithPath: "/x/" + name))
}

print("Kinds")
check("a disk image is an installer", kind("Thing-2.1.dmg") == .installer)
check("a package is an installer", kind("Setup.PKG") == .installer)
check("Xcode's xip is an installer", kind("Xcode_26.xip") == .installer)
check("an ISO is not -- it is as often a VM's disk", kind("ubuntu.iso") == nil)
check("Chrome's partial download", kind("video.mp4.crdownload") == .incomplete)
check("Safari's partial download", kind("video.mp4.download") == .incomplete)
check("Firefox's partial download", kind("video.mp4.part") == .incomplete)
check("a finished video is neither", kind("video.mp4") == nil)
check("a zip is neither -- it may be the only copy of something", kind("photos.zip") == nil)

print("What is offered")
let now = Date()
let day: TimeInterval = 86_400
func item(_ kind: StaleDownloads.Kind, added: TimeInterval, modified: TimeInterval,
          path: String = "/Users/x/Downloads/file") -> StaleDownloads.Item {
    StaleDownloads.Item(url: URL(fileURLWithPath: path), kind: kind, bytes: 1,
                        added: now.addingTimeInterval(-added), modified: now.addingTimeInterval(-modified))
}
check("a partial download written a minute ago may still be arriving",
      !StaleDownloads.isOffered(item(.incomplete, added: 60, modified: 60), mounted: [], now: now))
check("one untouched for two days is abandoned",
      StaleDownloads.isOffered(item(.incomplete, added: 3 * day, modified: 2 * day), mounted: [], now: now))
// Added long ago but written a moment ago: a download resumed today.
check("an old partial download that was resumed is not abandoned",
      !StaleDownloads.isOffered(item(.incomplete, added: 30 * day, modified: 30), mounted: [], now: now))
check("an installer is offered however new", StaleDownloads.isOffered(item(.installer, added: 60, modified: 60),
                                                                     mounted: [], now: now))
check("a mounted installer is not offered",
      !StaleDownloads.isOffered(item(.installer, added: 90 * day, modified: 90 * day),
                                mounted: ["/Users/x/Downloads/file"], now: now))

print("What arrives ticked")
check("an abandoned download is ticked",
      StaleDownloads.isTickedByDefault(item(.incomplete, added: 3 * day, modified: 2 * day), now: now))
check("an installer from this week is not",
      !StaleDownloads.isTickedByDefault(item(.installer, added: 3 * day, modified: 3 * day), now: now))
check("an installer from two months ago is",
      StaleDownloads.isTickedByDefault(item(.installer, added: 60 * day, modified: 60 * day), now: now))
// Ticking is by when it arrived, not when it was made: a dmg built a year
// ago and downloaded this morning has not been used yet.
check("an old file downloaded today is not ticked",
      !StaleDownloads.isTickedByDefault(item(.installer, added: 60, modified: 365 * day), now: now))

print("Mounted images, from hdiutil's own output")
let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>framework</key><string>672</string>
<key>images</key><array>
  <dict><key>image-path</key><string>/Users/x/Downloads/Thing.dmg</string></dict>
  <dict><key>image-path</key><string>/Users/x/Downloads/../Downloads/Other.dmg</string></dict>
  <dict><key>image-type</key><string>no path at all</string></dict>
</array></dict></plist>
"""
let mounted = StaleDownloads.mountedImages(fromPlist: Data(plist.utf8))
check("each attached image's file is read", mounted.contains("/Users/x/Downloads/Thing.dmg"))
check("paths are standardised", mounted.contains("/Users/x/Downloads/Other.dmg"))
check("an image with no path is skipped", mounted.count == 2)
check("output that is not a plist is nothing", StaleDownloads.mountedImages(fromPlist: Data("x".utf8)).isEmpty)
check("no images is nothing", StaleDownloads.mountedImages(fromPlist: Data(
    "<plist version=\"1.0\"><dict></dict></plist>".utf8)).isEmpty)

print("On a disk")
let fm = FileManager.default
let folder = fm.temporaryDirectory.appendingPathComponent("downloads-test-\(UUID().uuidString)")
try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
func make(_ name: String, bytes: Int, modified: Date) -> URL {
    let url = folder.appendingPathComponent(name)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
    try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}
let old = now.addingTimeInterval(-5 * day)
_ = make("Big.dmg", bytes: 300_000, modified: old)
_ = make("Small.pkg", bytes: 10_000, modified: old)
_ = make("stale.mp4.crdownload", bytes: 50_000, modified: old)
_ = make("fresh.mp4.crdownload", bytes: 50_000, modified: now)
_ = make("report.pdf", bytes: 400_000, modified: old)
_ = make("Filed/Kept.dmg", bytes: 300_000, modified: old)
// A Safari bundle whose own date is old but whose payload is being written now.
let bundle = folder.appendingPathComponent("movie.mov.download")
try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
_ = make("movie.mov.download/movie.mov", bytes: 80_000, modified: now)
try? fm.setAttributes([.modificationDate: old], ofItemAtPath: bundle.path)

let found = StaleDownloads.find(in: folder, mounted: [], now: now)
let names = found.map(\.name)
check("installers are found", names.contains("Big.dmg") && names.contains("Small.pkg"))
check("an abandoned download is found", names.contains("stale.mp4.crdownload"))
check("one still arriving is not", !names.contains("fresh.mp4.crdownload"))
check("Safari's bundle is judged by what is inside it", !names.contains("movie.mov.download"))
check("a PDF is not", !names.contains("report.pdf"))
check("an installer filed into a subfolder is left alone", !names.contains("Kept.dmg"))
check("biggest first", names.first == "Big.dmg")
check("a mounted installer is not found",
      !StaleDownloads.find(in: folder, mounted: [folder.appendingPathComponent("Big.dmg").path], now: now)
        .map(\.name).contains("Big.dmg"))

print("Checked again before the Bin")
if let big = found.first(where: { $0.name == "Big.dmg" }) {
    check("an untouched file is unchanged", StaleDownloads.isUnchanged(big, in: folder, mounted: []))
    check("one mounted since is refused",
          !StaleDownloads.isUnchanged(big, in: folder, mounted: [big.url.path]))
    check("one in another folder is refused",
          !StaleDownloads.isUnchanged(big, in: fm.temporaryDirectory, mounted: []))
    try? fm.setAttributes([.modificationDate: now], ofItemAtPath: big.url.path)
    check("one written since is refused", !StaleDownloads.isUnchanged(big, in: folder, mounted: []))
    try? fm.removeItem(at: big.url)
    check("one that has gone is refused", !StaleDownloads.isUnchanged(big, in: folder, mounted: []))
}

try? fm.removeItem(at: folder)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
