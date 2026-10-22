//
//  spacemap-test.swift
//
//  Exercises the space map: the walk that adds a folder up, the folding that
//  keeps it small, and the layout that draws it.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Cleanup/LargeFiles.swift \
//            Roost/Cleanup/SpaceMap.swift Tools/spacemap-test.swift | swift -
//
//  A treemap that is wrong still looks like a treemap, which is what makes
//  its invariants worth writing down: every rectangle inside the frame, none
//  overlapping, each in proportion to its size, and the sizes adding up to
//  what is really on the disk.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: - Layout

print("Layout")
let frame = CGRect(x: 10, y: 20, width: 600, height: 400)
let sizes: [Double] = [500, 300, 120, 80, 40, 30, 12, 8, 5, 1]
let rects = SpaceMap.squarify(sizes, in: frame)
check("one rectangle per size", rects.count == sizes.count)
check("every rectangle is inside the frame", rects.allSatisfy {
    frame.insetBy(dx: -0.001, dy: -0.001).contains($0) })
var overlaps = false
for i in rects.indices { for j in rects.indices where j > i {
    let shared = rects[i].intersection(rects[j])
    if !shared.isNull, shared.width > 0.001, shared.height > 0.001 { overlaps = true }
} }
check("no two rectangles overlap", !overlaps)
let total = sizes.reduce(0, +)
let area = Double(frame.width * frame.height)
let proportional = zip(sizes, rects).allSatisfy { size, rect in
    abs(Double(rect.width * rect.height) - size / total * area) < 0.5
}
check("each area is in proportion to its size", proportional)
let filled = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
check("together they fill the frame", abs(filled - area) < 1)
// The reason for squarifying: slice-and-dice would give the 1 a sliver of
// 600 x 0.4 points. Squarified rectangles stay readable.
let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? .infinity
check("no rectangle is a sliver (worst aspect ratio under 6)", worst < 6)
check("an empty list is no rectangles", SpaceMap.squarify([], in: frame).isEmpty)
check("all-zero sizes are empty rectangles, still one each",
      SpaceMap.squarify([0, 0], in: frame) == [.zero, .zero])
check("a zero among sizes gets an empty rectangle and leaves the rest alone",
      SpaceMap.squarify([10, 0, 5], in: frame)[1] == .zero
        && SpaceMap.squarify([10, 0, 5], in: frame)[2].width > 0)
check("a zero-sized frame is empty rectangles",
      SpaceMap.squarify([1, 2], in: .zero).allSatisfy { $0 == .zero })
// Within a hundredth of a point: 42 x (area / 42) is not exactly the area in
// floating point, and a frame off by 1e-13 is still the frame.
let single = SpaceMap.squarify([42], in: frame)[0]
check("a single size fills the frame", abs(single.minX - frame.minX) < 0.01
      && abs(single.minY - frame.minY) < 0.01 && abs(single.width - frame.width) < 0.01
      && abs(single.height - frame.height) < 0.01)

// MARK: - Folding

print("Folding")
let parent = URL(fileURLWithPath: "/x")
func leaf(_ name: String, _ bytes: Int64) -> SpaceMap.Node {
    SpaceMap.Node(name: name, url: parent.appendingPathComponent(name), kind: .file, bytes: bytes)
}
let many = (0..<50).map { leaf("f\($0)", Int64($0 + 1)) }
let folded = SpaceMap.folded(many, keep: 10, parent: parent)
check("keeps the largest and one entry for the rest", folded.count == 11)
check("biggest first", folded.first?.bytes == 50)
if case .smaller(let count)? = folded.last?.kind {
    check("the folded entry counts what it holds", count == 40)
} else {
    check("the folded entry counts what it holds", false)
}
check("folding loses no bytes",
      folded.reduce(0) { $0 + $1.bytes } == many.reduce(0) { $0 + $1.bytes })
check("a short list is only sorted", SpaceMap.folded([leaf("a", 1), leaf("b", 9)], keep: 10,
                                                     parent: parent).map(\.name) == ["b", "a"])
check("equal sizes keep name order",
      SpaceMap.folded([leaf("b", 5), leaf("a", 5), leaf("c", 5)], keep: 10, parent: parent)
        .map(\.name) == ["a", "b", "c"])

// MARK: - On a disk

print("Walking")
let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent("spacemap-test-\(UUID().uuidString)")
func make(_ path: String, bytes: Int) {
    let url = home.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
}
make("Movies/trip.mov", bytes: 3_000_000)
make("Movies/clips/a.mov", bytes: 1_000_000)
make("Documents/notes.txt", bytes: 10_000)
make("Applications/Tool.app/Contents/MacOS/Tool", bytes: 2_000_000)
make("Library/Containers/com.other.app/Data/big.bin", bytes: 5_000_000)
make("Elsewhere/target.bin", bytes: 4_000_000)
try? fm.createSymbolicLink(at: home.appendingPathComponent("Documents/link"),
                           withDestinationURL: home.appendingPathComponent("Elsewhere"))
try? fm.createDirectory(at: home.appendingPathComponent("Locked"), withIntermediateDirectories: true)
make("Locked/secret.bin", bytes: 1_000_000)
try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.appendingPathComponent("Locked").path)

let map = SpaceMap.scan(home, home: home)
let tree = map.root
func child(_ node: SpaceMap.Node?, _ name: String) -> SpaceMap.Node? {
    node?.children.first { $0.name == name }
}
let movies = child(tree, "Movies")
check("a folder is the sum of what is in it",
      movies.map { $0.bytes == $0.children.reduce(0) { $0 + $1.bytes } } == true)
check("and at least what was written into it", (movies?.bytes ?? 0) >= 4_000_000)
check("biggest child first", movies?.children.first?.name == "trip.mov")
let app = child(child(tree, "Applications"), "Tool.app")
check("an app is one thing", app?.kind == .package && app?.children.isEmpty == true)
check("and measured whole", (app?.bytes ?? 0) >= 2_000_000)
let library = child(tree, "Library")
check("another app's containers are not opened, so their size is not claimed",
      (library?.bytes ?? .max) == 0)
// Library holds nothing else here, so it is small enough to be pruned --
// which is the case that lost the note until it was recorded separately.
check("and the map says they were not measured, even after pruning",
      map.notMeasured.map(\.lastPathComponent) == ["Containers"])
let documents = child(tree, "Documents")
check("a symlink is not followed", (documents?.bytes ?? .max) < 1_000_000)
let locked = child(tree, "Locked")
check("a folder that cannot be opened says so", locked?.kind == .unreadable)
check("and the count reaches the top", tree.unreadable >= 1)
check("a complete walk is not partial", !tree.isPartial)
check("the root is the sum of its children",
      tree.bytes == tree.children.reduce(0) { $0 + $1.bytes })

print("Pruning")
var deep = SpaceMap.Node(name: "root", url: parent, kind: .folder, bytes: 1000)
var small = SpaceMap.Node(name: "small", url: parent.appendingPathComponent("small"), kind: .folder, bytes: 4)
small.children = [leaf("tiny", 4)]
var big = SpaceMap.Node(name: "big", url: parent.appendingPathComponent("big"), kind: .folder, bytes: 996)
big.children = [leaf("huge", 996)]
deep.children = [big, small]
let pruned = SpaceMap.pruned(deep, below: 10)
check("a folder too small to draw drops its contents", pruned.children[1].children.isEmpty)
check("and says it was collapsed, so opening it walks it again", pruned.children[1].isCollapsed)
check("but keeps its size", pruned.children[1].bytes == 4)
check("a folder big enough keeps its contents", pruned.children[0].children.count == 1)
check("and is not collapsed", !pruned.children[0].isCollapsed)
check("the total is unchanged", pruned.bytes == deep.bytes)

print("Finding a node")
check("by URL", SpaceMap.node(at: home.appendingPathComponent("Movies/clips"), in: tree)?.name == "clips")
check("the root is itself", SpaceMap.node(at: home, in: tree)?.url == tree.url)
check("a path outside is nothing", SpaceMap.node(at: URL(fileURLWithPath: "/nowhere"), in: tree) == nil)
check("a prefix that is not a parent is nothing",
      SpaceMap.node(at: home.appendingPathComponent("Movi"), in: tree) == nil)

print("Opening a collapsed folder")
var opened = pruned.children[1]
opened.children = [leaf("tiny", 4)]
opened.isCollapsed = false
let grafted = SpaceMap.replacing(opened.url, with: opened, in: pruned)
check("the folder walked again goes back where it was", grafted.children[1].children.count == 1)
check("and is no longer collapsed", !grafted.children[1].isCollapsed)
check("nothing else changes", grafted.children[0] == pruned.children[0] && grafted.bytes == pruned.bytes)
check("a URL that is not in the tree changes nothing",
      SpaceMap.replacing(URL(fileURLWithPath: "/elsewhere"), with: opened, in: pruned) == pruned)

print("Removing")
func removable(_ node: SpaceMap.Node?) -> Bool {
    node.map { SpaceMap.isRemovable($0, root: home, home: home) } ?? false
}
let trip = child(movies, "trip.mov")
check("a file in a home folder can be ticked", removable(trip))
check("so can a folder inside one", removable(child(movies, "clips")))
check("and an app found in the map", removable(app))
check("but not the home folder's own folders", !removable(movies) && !removable(documents))
check("nor anything in ~/Library, however deep",
      !SpaceMap.isRemovable(SpaceMap.Node(name: "x", url: home.appendingPathComponent("Library/Mail/V10"),
                                          kind: .folder, bytes: 1), root: home, home: home))
check("nor the folder being mapped", !removable(tree))
let elsewhere = child(tree, "Elsewhere")
check("a folder of the user's own next to them can", removable(elsewhere))
let unfinished = SpaceMap.Node(name: "bbb", url: home.appendingPathComponent("Elsewhere/bbb"),
                               kind: .folder, bytes: 0, isPartial: true)
check("nor a folder the walk stopped before measuring -- it would be \"Move Zero KB\"",
      !SpaceMap.isRemovable(unfinished, root: home, home: home))
check("nor what only stands for something: smaller items, unreadable, unmeasured",
      !SpaceMap.isRemovable(SpaceMap.Node(name: "", url: home.appendingPathComponent("Movies/x"),
                                          kind: .smaller(count: 3), bytes: 9), root: home, home: home)
      && !removable(locked))
check("outside home only another disk's contents, never the system's",
      SpaceMap.isRemovable(SpaceMap.Node(name: "a", url: URL(fileURLWithPath: "/Volumes/Backup/a.mov"),
                                         kind: .file, bytes: 1), root: URL(fileURLWithPath: "/Volumes/Backup"),
                           home: home)
      && !SpaceMap.isRemovable(SpaceMap.Node(name: "Backup", url: URL(fileURLWithPath: "/Volumes/Backup"),
                                             kind: .folder, bytes: 1), root: URL(fileURLWithPath: "/Volumes"),
                               home: home)
      && !SpaceMap.isRemovable(SpaceMap.Node(name: "Foo.app", url: URL(fileURLWithPath: "/Applications/Foo.app"),
                                             kind: .package, bytes: 1), root: URL(fileURLWithPath: "/"),
                               home: home))

let clips = home.appendingPathComponent("Movies/clips")
let collapsed: [URL] = SpaceMap.collapsed([clips, clips.appendingPathComponent("a.mov"),
                                           home.appendingPathComponent("Movies/trip.mov")])
check("a ticked folder takes what is inside it with it",
      collapsed.map(\.lastPathComponent) == ["clips", "trip.mov"])
check("a name that only starts like a folder is not inside it",
      SpaceMap.collapsed([home.appendingPathComponent("a"),
                          home.appendingPathComponent("ab")]).count == 2)

check("a file just measured is unchanged", trip.map(SpaceMap.isUnchanged) == true)
make("Movies/trip.mov", bytes: 3_500_000)
check("and is not once it has been written to", trip.map(SpaceMap.isUnchanged) == false)
check("a folder still there is", elsewhere.map(SpaceMap.isUnchanged) == true)
check("a file that is gone is not",
      !SpaceMap.isUnchanged(SpaceMap.Node(name: "gone", url: home.appendingPathComponent("gone.bin"),
                                          kind: .file, bytes: 1)))

let tripURL: URL = home.appendingPathComponent("Movies/trip.mov").standardizedFileURL
let after = SpaceMap.removing([tripURL], from: tree)
let moviesAfter = child(after, "Movies")
check("a removed file leaves the map", child(moviesAfter, "trip.mov") == nil)
check("and its folder is smaller by what it held",
      (movies?.bytes ?? 0) - (moviesAfter?.bytes ?? 0) == (trip?.bytes ?? -1))
check("and so is everything above it", tree.bytes - after.bytes == (trip?.bytes ?? -1))
check("removing nothing changes nothing", SpaceMap.removing([], from: tree) == tree)

print("Stopping")
let stopped = SpaceMap.scan(home, home: home, shouldStop: { true }).root
check("a stopped walk says it is partial", stopped.isPartial)
let late = SpaceMap.scan(home, home: home, deadline: Date().addingTimeInterval(-1)).root
check("one past its deadline does too", late.isPartial)

try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Locked").path)
try? fm.removeItem(at: home)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
