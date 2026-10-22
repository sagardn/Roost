//
//  duplicates-test.swift
//
//  Exercises the duplicate finder: what counts as the same file, what space
//  removing a copy really gives back, and the rule that one copy always stays.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/Duplicates.swift Tools/duplicates-test.swift | swift -
//
//  Against files made here, on the temporary directory's APFS volume, because
//  the cases that matter -- a hard link, a clone, two files that agree for
//  64 KB and then differ -- are properties of the file system, and a fake
//  could only agree with what this suite already believes about them.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("duplicates-test-\(UUID().uuidString)")
try? fm.createDirectory(at: root, withIntermediateDirectories: true)

let megabyte = 1 << 20
/// Deterministic bytes, different per seed, so two seeds never collide.
func bytes(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}
@discardableResult
func write(_ path: String, _ data: Data, modified: Date? = nil) -> URL {
    let url = root.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: data)
    if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    return url
}

let original = bytes(2 * megabyte, seed: 1)
let day: TimeInterval = 86_400
let now = Date()
write("Documents/report.mov", original, modified: now.addingTimeInterval(-10 * day))
write("Downloads/report (1).mov", original, modified: now.addingTimeInterval(-2 * day))
write("Desktop/report copy.mov", original, modified: now)

// Same length, same first 64 KB, different after: must be split by the full hash.
var lateDiffer = original
lateDiffer[megabyte + 5] ^= 0xFF
write("Documents/almost.mov", lateDiffer)

// Same length, different from the first byte.
write("Documents/other.mov", bytes(2 * megabyte, seed: 9))

// Too small to report, though identical.
write("Documents/icon-a.png", bytes(40_000, seed: 3))
write("Documents/icon-b.png", bytes(40_000, seed: 3))

// A hard link: one file, two names.
let linked = write("Music/song.m4a", bytes(megabyte + 1, seed: 4))
try? fm.linkItem(at: linked, to: root.appendingPathComponent("Music/song link.m4a"))

// A clone: two files, one set of blocks. `copyItem` clones on APFS --
// measured, and checked again below rather than assumed.
let photo = write("Pictures/photo.heic", bytes(megabyte + 7, seed: 5))
try? fm.copyItem(at: photo, to: root.appendingPathComponent("Pictures/photo clone.heic"))
// And a real copy of the same photo, made by writing the bytes again.
write("Pictures/photo copy.heic", bytes(megabyte + 7, seed: 5))

// Inside a project's dependencies and inside a bundle: identical by design.
write("Documents/site/node_modules/a/lib.bin", bytes(megabyte, seed: 6))
write("Documents/site/node_modules/b/lib.bin", bytes(megabyte, seed: 6))
write("Documents/Thing.app/Contents/Resources/big.bin", bytes(megabyte, seed: 7))
write("Desktop/big.bin", bytes(megabyte, seed: 7))

let scan = Duplicates.scan(roots: ["Documents", "Downloads", "Desktop", "Music", "Pictures"]
    .map { root.appendingPathComponent($0) })

func group(containing name: String) -> Duplicates.Group? {
    scan.groups.first { $0.files.contains { $0.name == name } }
}

print("What counts as the same")
check("the scan finished", scan.isComplete)
check("three copies are one group of three", group(containing: "report.mov")?.files.count == 3)
check("a file that differs after the first block is not a copy",
      group(containing: "almost.mov") == nil)
check("a file that differs from the start is not a copy", group(containing: "other.mov") == nil)
check("files under the minimum are not reported", group(containing: "icon-a.png") == nil)
let linkCount = (try? fm.attributesOfItem(atPath: linked.path)[.referenceCount] as? Int) ?? 0
check("the hard link really was made (checked, not assumed)", linkCount == 2)
check("a hard link is one file, not a pair", group(containing: "song.m4a") == nil)
check("nothing inside node_modules is offered",
      !scan.groups.contains { $0.files.contains { $0.url.path.contains("/node_modules/") } })
check("nothing inside an app bundle is offered",
      !scan.groups.contains { $0.files.contains { $0.url.path.contains(".app/") } })
check("so a file outside it has no copy", group(containing: "big.bin") == nil)

print("Order")
let report = group(containing: "report.mov")
check("oldest copy first", report?.files.first?.name == "report.mov")
check("newest copy last", report?.files.last?.name == "report copy.mov")

print("Space given back")
let photos = group(containing: "photo.heic")
check("a clone, its original and a real copy are one group of three", photos?.files.count == 3)
let ids = photos?.files.map(\.content) ?? []
check("the clone really shares its original's data stream (checked, not assumed)",
      Set(ids.compactMap { $0 }).count == 2)
let photoSize = photos?.files.map(\.allocated).max() ?? 0
// Two data streams among three files: removing every spare gives back one
// file's worth, not two.
check("a clone adds nothing to what can be given back", photos?.reclaimable == photoSize)
if let photos {
    let clone = photos.files.first { $0.name == "photo clone.heic" }!
    let copy = photos.files.first { $0.name == "photo copy.heic" }!
    check("trashing a clone alone frees nothing", !photos.freesSpace(clone))
    check("trashing the real copy does", photos.freesSpace(copy))
}
if let photos {
    let clone = photos.files.first { $0.name == "photo clone.heic" }!.url
    let original = photos.files.first { $0.name == "photo.heic" }!.url
    let copy = photos.files.first { $0.name == "photo copy.heic" }!.url
    // Found in review: counted file by file, ticking both twins of a clone
    // pair said 0 bytes, though their shared blocks do come back.
    check("both twins of a clone free their shared blocks once",
          photos.freed(by: [clone, original]) == photoSize)
    check("one twin alone frees nothing", photos.freed(by: [clone]) == 0)
    check("the real copy frees its own", photos.freed(by: [copy]) == photoSize)
    check("nothing ticked frees nothing", photos.freed(by: []) == 0)
}
let reportSize = report?.files.map(\.allocated).max() ?? 0
check("three real copies give back two files' worth", report?.reclaimable == 2 * reportSize)
check("groups are ordered by what they give back",
      scan.groups.first.map { $0.reclaimable >= (scan.groups.last?.reclaimable ?? 0) } == true)

print("Grouping, written down")
func file(_ name: String, _ length: Int64, resource: UInt8? = nil, content: Int64? = nil) -> Duplicates.File {
    Duplicates.File(url: URL(fileURLWithPath: "/x/" + name), length: length, allocated: length,
                    modified: .distantPast, resource: resource.map { Data([$0]) }, content: content)
}
let byName: [String: Data] = ["a": Data([1]), "b": Data([1]), "c": Data([2])]
let hashed = Duplicates.groups([file("a", 5_000_000), file("b", 5_000_000), file("c", 5_000_000)],
                               hash: { url, _ in byName[url.lastPathComponent] })
check("files are grouped by hash", hashed.count == 1 && hashed[0].files.map(\.name) == ["a", "b"])
let unreadable = Duplicates.groups([file("a", 5_000_000), file("b", 5_000_000)],
                                   hash: { url, _ in url.lastPathComponent == "a" ? Data([1]) : nil })
check("a file that cannot be read is never assumed equal", unreadable.isEmpty)
var fullHashes = 0
_ = Duplicates.groups([file("a", 1000), file("b", 1000)], hash: { _, limit in
    if limit == nil { fullHashes += 1 }
    return Data([1])
})
check("a file shorter than the head is not hashed twice", fullHashes == 0)
var lengthsHashed: [Int64] = []
_ = Duplicates.groups([file("a", 9_000_000), file("b", 8_000_000)], hash: { url, _ in
    lengthsHashed.append(url.lastPathComponent == "a" ? 9 : 8)
    return Data([1])
})
check("files of different lengths are never read", lengthsHashed.isEmpty)
let links = Duplicates.collapsingHardLinks([file("a", 1, resource: 1), file("b", 1, resource: 1),
                                            file("c", 1, resource: 2)])
check("hard links collapse to the first name", links.map(\.name) == ["a", "c"])

print("One copy always stays")
if let report {
    let all = Set(report.files.map(\.url))
    check("ticking every copy is refused", !Duplicates.keepsACopyOfEach(all, in: scan.groups))
    var allButOne = all
    allButOne.remove(report.files[0].url)
    check("leaving one is allowed", Duplicates.keepsACopyOfEach(allButOne, in: scan.groups))
    check("nothing ticked is allowed", Duplicates.keepsACopyOfEach([], in: scan.groups))
    let keepOldest = Duplicates.spares(in: report, keeping: .oldest)
    check("keeping the oldest ticks the other two",
          keepOldest.count == 2 && !keepOldest.contains(report.files.first!.url))
    let keepNewest = Duplicates.spares(in: report, keeping: .newest)
    check("keeping the newest ticks the other two",
          keepNewest.count == 2 && !keepNewest.contains(report.files.last!.url))
    var every = Set<URL>()
    for group in scan.groups { every.formUnion(Duplicates.spares(in: group, keeping: .oldest)) }
    check("the spares of every group still keep a copy of each",
          Duplicates.keepsACopyOfEach(every, in: scan.groups))
}

print("Checked again before the Bin")
if let copy = report?.files.last {
    check("an untouched copy is unchanged", Duplicates.isUnchanged(copy))
    var edited = original
    edited[0] ^= 1
    edited.append(0)
    try? edited.write(to: copy.url)
    check("an edited copy is refused", !Duplicates.isUnchanged(copy))
    try? fm.removeItem(at: copy.url)
    check("a copy that has gone is refused", !Duplicates.isUnchanged(copy))
}

print("Stopping")
let stopped = Duplicates.scan(roots: [root], shouldStop: { true })
check("a stopped scan says it is incomplete", !stopped.isComplete)
let late = Duplicates.scan(roots: [root], deadline: Date().addingTimeInterval(-1))
check("a scan past its deadline says it is incomplete", !late.isComplete)

try? fm.removeItem(at: root)
print("\nHard links outside the comparison")
do {
    func linked(_ name: String, links: Int) -> Duplicates.File {
        Duplicates.File(url: URL(fileURLWithPath: "/x/" + name), length: 1_000, allocated: 1_000,
                        modified: .distantPast, resource: nil, content: nil, links: links)
    }
    // Two copies, one of which has a second name elsewhere on the disk.
    let pair = Duplicates.Group(files: [linked("kept.mov", links: 2), linked("copy.mov", links: 1)])
    check("the copy with another name frees nothing on its own",
          !pair.freesSpace(pair.files[0]))
    check("the plain copy still does", pair.freesSpace(pair.files[1]))
    check("ticking the linked copy frees nothing",
          pair.freed(by: [pair.files[0].url]) == 0)
    check("ticking the plain copy frees its size", pair.freed(by: [pair.files[1].url]) == 1_000)
    check("what can be reclaimed is the plain copy, keeping the linked one",
          pair.reclaimable == 1_000)
    let bothLinked = Duplicates.Group(files: [linked("a", links: 2), linked("b", links: 3)])
    check("two copies that both have other names reclaim nothing", bothLinked.reclaimable == 0)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
