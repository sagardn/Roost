//
//  tile-test.swift
//
//  Renders the module tiles the combined details popup stacks, and looks at
//  them.
//
//  Run:  cat Roost/UI/Palette.swift Roost/UI/Localized.swift \
//            Roost/Monitor/Readings.swift Roost/Monitor/CPUReadings.swift \
//            Roost/Monitor/ProcessNetwork.swift Roost/UI/Alert.swift \
//            Roost/Launcher/Notify.swift Roost/Monitor/ProcessControl.swift \
//            Roost/Monitor/PopupSection.swift Roost/Monitor/ProcessIdentity.swift \
//            Roost/Monitor/MemoryReadings.swift Roost/Monitor/CPUTile.swift \
//            Roost/Monitor/RAMTile.swift Roost/Monitor/DiskReadings.swift \
//            Roost/Monitor/DiskTile.swift Tools/tile-test.swift | swift -
//
//  NetworkTile is not here: it takes a live NetworkMonitor, which is a
//  singleton holding a timer and interface counters, and standing one up in a
//  script would test the harness rather than the tile. Its layout is the same
//  three-row shape as these two and its chart is covered by widget-test.
//
//  Writes /tmp/cpu-tile.png. Drawing is the one thing a geometry assertion
//  cannot cover, and a view renders into a bitmap without a window -- so a
//  tile can be looked at on a machine whose screen is locked, which is more
//  than can be said for the menu bar.
//
//  Two things about rendering offscreen, both learned the hard way:
//  an appearance has to be set, or the dynamic label colours resolve to
//  nothing and every caption comes out invisible; and the bitmap starts
//  transparent, so it needs filling before the view draws into it or light
//  text sits on nothing.
//
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// Renders a tile onto white and writes it out.
func render(_ view: NSView, to path: String) -> Bool {
    view.appearance = NSAppearance(named: .aqua)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]), png.count > 1000
    else { return false }
    try? png.write(to: URL(fileURLWithPath: path))
    return true
}

// MARK: - CPU

print("CPUTile")

let width = PopupMetrics.contentWidth
let tile = CPUTile()
tile.translatesAutoresizingMaskIntoConstraints = true
tile.frame = NSRect(x: 0, y: 0, width: width, height: CPUTile.height)

// A sample that exercises every part of it: a machine working its
// performance cluster while the efficiency cluster idles, which is the normal
// shape on Apple silicon and the reason the tile splits them.
let loads = [0.12, 0.18, 0.09, 0.22, 0.91, 0.84, 0.76, 0.95]
let cores = loads.map { CPUReadings.CoreLoad(total: $0, user: $0 * 0.65, system: $0 * 0.35) }
tile.update(CPUReadings.Load(cores: cores, user: 0.341, system: 0.179))
tile.layoutSubtreeIfNeeded()

check("the tile is the height it claims", abs(tile.frame.height - CPUTile.height) < 0.5)
check("the tile fills the popup's content width", abs(tile.frame.width - width) < 0.5)

let boxes = tile.subviews.map { $0.frame }
check("nothing is zero-sized", boxes.allSatisfy { $0.width > 0 && $0.height > 0 })

// 2.5pt of slack on the sides: a label's frame sits two points outside its
// own text so the glyphs line up with everything else, so a label pinned to
// an edge reports a frame two points past it.
check("nothing escapes the tile",
      boxes.allSatisfy { $0.minX >= -2.5 && $0.maxX <= width + 2.5
                      && $0.minY >= -0.5 && $0.maxY <= CPUTile.height + 0.5 })

// Four things stacked, none of them on top of another. Bottom-up, because
// that is the coordinate system.
let rows = boxes.sorted { $0.minY < $1.minY }
check("there are four rows", rows.count == 4)
check("the rows do not overlap",
      zip(rows, rows.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 }
      // The caption and the figure share the top line by design.
      || zip(rows.dropLast(), rows.dropFirst().dropLast())
            .allSatisfy { $0.maxY <= $1.minY + 0.5 })

check("the tile renders", render(tile, to: "/tmp/cpu-tile.png"))

// MARK: - RAM

print("\nRAMTile")

let ramTile = RAMTile()
ramTile.translatesAutoresizingMaskIntoConstraints = true
ramTile.frame = NSRect(x: 0, y: 0, width: width, height: RAMTile.height)

// A machine under real pressure: most of it taken, and swapping.
let gigabyte: UInt64 = 1_073_741_824
let usage = MemoryReadings.Usage(total: 16 * gigabyte,
                                 app: 8 * gigabyte,
                                 wired: 3 * gigabyte,
                                 compressed: 2 * gigabyte,
                                 cached: 2 * gigabyte,
                                 free: gigabyte / 2)
ramTile.update(usage, swap: .init(total: 4 * gigabyte, used: gigabyte + gigabyte / 2),
               pressure: .warning)
ramTile.layoutSubtreeIfNeeded()

check("the used share is what Activity Monitor calls used",
      usage.used == 13 * gigabyte)
check("the percentage follows from it", abs(usage.percent - 13.0 / 16) < 0.0001)
check("the tile is the height it claims",
      abs(ramTile.frame.height - RAMTile.height) < 0.5)

let ramBoxes = ramTile.subviews.map { $0.frame }
check("nothing is zero-sized", ramBoxes.allSatisfy { $0.width > 0 && $0.height > 0 })
check("nothing escapes the tile",
      ramBoxes.allSatisfy { $0.minX >= -2.5 && $0.maxX <= width + 2.5
                         && $0.minY >= -0.5 && $0.maxY <= RAMTile.height + 0.5 })
check("the tile renders", render(ramTile, to: "/tmp/ram-tile.png"))

do {
    // A machine with nothing to report must not claim swap it has not used.
    let quiet = RAMTile()
    quiet.translatesAutoresizingMaskIntoConstraints = true
    quiet.frame = NSRect(x: 0, y: 0, width: width, height: RAMTile.height)
    quiet.update(MemoryReadings.Usage(total: 16 * gigabyte, app: gigabyte, wired: gigabyte,
                                      compressed: 0, cached: gigabyte, free: 13 * gigabyte),
                 swap: .init(total: 0, used: 0), pressure: .normal)
    check("an idle machine renders too", render(quiet, to: "/tmp/ram-tile-idle.png"))
}

do {
    // Readings that cannot happen, but which a kernel call can still return.
    let broken = RAMTile()
    broken.translatesAutoresizingMaskIntoConstraints = true
    broken.frame = NSRect(x: 0, y: 0, width: width, height: RAMTile.height)
    broken.update(MemoryReadings.Usage(total: 0, app: 0, wired: 0,
                                       compressed: 0, cached: 0, free: 0),
                  swap: nil, pressure: .critical)
    check("a machine reporting no memory at all does not crash",
          render(broken, to: "/tmp/ram-tile-zero.png"))
}

// MARK: - Disk

print("\nDiskTile")

let diskTile = DiskTile()
diskTile.translatesAutoresizingMaskIntoConstraints = true
diskTile.frame = NSRect(x: 0, y: 0, width: width, height: DiskTile.height)

// The machine this was written on: 182 GiB of container with 4.6 left.
let volume = DiskReadings.Volume(name: "Macintosh HD", path: "/",
                                 total: 195_383_263_232, free: 4_888_379_392,
                                 freeNow: 4_888_379_392,
                                 isRemovable: false, isInternal: true, format: "APFS")
diskTile.update(volume,
                activity: .init(read: 4_200_000, written: 1_100_000),
                history: (0..<60).map { 0.96 + Double($0) / 6000 })
diskTile.layoutSubtreeIfNeeded()

check("the tile is the height it claims",
      abs(diskTile.frame.height - DiskTile.height) < 0.5)
let diskBoxes = diskTile.subviews.map { $0.frame }
check("nothing is zero-sized", diskBoxes.allSatisfy { $0.width > 0 && $0.height > 0 })
check("nothing escapes the tile",
      diskBoxes.allSatisfy { $0.minX >= -2.5 && $0.maxX <= width + 2.5
                          && $0.minY >= -0.5 && $0.maxY <= DiskTile.height + 0.5 })
check("the tile renders", render(diskTile, to: "/tmp/disk-tile.png"))

do {
    // An idle disk: the rates are left off rather than printed as zero.
    let idle = DiskTile()
    idle.translatesAutoresizingMaskIntoConstraints = true
    idle.frame = NSRect(x: 0, y: 0, width: width, height: DiskTile.height)
    idle.update(volume, activity: .init(), history: [])
    check("an idle disk renders", render(idle, to: "/tmp/disk-tile-idle.png"))
}

do {
    // A volume reporting nothing at all, and a rate that is not a number.
    let broken = DiskTile()
    broken.translatesAutoresizingMaskIntoConstraints = true
    broken.frame = NSRect(x: 0, y: 0, width: width, height: DiskTile.height)
    broken.update(DiskReadings.Volume(name: "?", path: "/x", total: 0, free: 0,
                                      freeNow: 0,
                                      isRemovable: false, isInternal: false, format: nil),
                  activity: .init(read: .nan, written: .infinity), history: [.nan])
    check("a volume reporting nothing does not crash",
          render(broken, to: "/tmp/disk-tile-zero.png"))
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
