//
//  dockclick-probe.swift
//
//  Reads the real Dock: the live half of dockclick-test.swift.
//
//  Run:  cat Roost/Launcher/DockClick.swift Tools/dockclick-probe.swift | swift -
//
//  A probe, not a suite -- the runner leaves *-probe files alone -- because
//  it needs a desktop, a Dock, and Accessibility, and CI has none of them.
//
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

guard AXIsProcessTrusted() else {
    print("no Accessibility grant for this process; cannot read the Dock")
    exit(0)
}

let start = Date()
let items = DockClick.items()
let first = Date().timeIntervalSince(start) * 1000

var times: [Double] = []
for _ in 0..<20 {
    let t = Date()
    _ = DockClick.items()
    times.append(Date().timeIntervalSince(t) * 1000)
}
let average = times.reduce(0, +) / Double(times.count)

print(String(format: "DockClick.items(): %d items, %.2f ms first read, %.2f ms average",
             items.count, first, average))
print("  running: \(items.filter { $0.isRunning }.count), not running: \(items.filter { !$0.isRunning }.count)")

guard let sample = items.first else { print("  no items — is the Dock hidden?"); exit(0) }
print("  first item: \(sample.bundleID) at \(sample.frame)")

// Every item must identify an app and have a frame with area, or hit
// testing silently matches nothing.
let bad = items.filter { $0.bundleID.isEmpty || $0.frame.isEmpty }
print(bad.isEmpty ? "  every item has a bundle id and a frame"
                  : "  \(bad.count) item(s) unusable: \(bad.map(\.bundleID))")

// Frames must not overlap, or a click would hit whichever came first.
var overlaps = 0
for (i, a) in items.enumerated() {
    for b in items.dropFirst(i + 1) where a.frame.intersects(b.frame) { overlaps += 1 }
}
print(overlaps == 0 ? "  no two icons overlap" : "  \(overlaps) overlapping pair(s)")

// The pointer is somewhere; say what it is over, which is the whole
// mechanism in one line.
let mouse = NSEvent.mouseLocation
let flipped = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
print("  pointer at \(flipped) is over: \(DockClick.hit(flipped, in: items)?.bundleID ?? "nothing")")
