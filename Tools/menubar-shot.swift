//
//  menubar-shot.swift
//
//  Draws the README's menu bar strip from the app's own widget code.
//
//  Run:  cat Roost/UI/Palette.swift Roost/UI/Localized.swift \
//            Roost/Settings/Preferences.swift Roost/Monitor/MenuBarStyle.swift \
//            Roost/Monitor/MenuBarWidget.swift Roost/Monitor/Readings.swift \
//            Tools/menubar-shot.swift | swift - docs/screenshots/menubar.png
//
//  Rendered rather than captured. A capture needs the real menu bar on
//  screen, which a full-screen app hides -- the first attempt at this came
//  back as a black strip -- and it carries whatever else sits in the bar,
//  which a README of Roost should not advertise. Drawing MenuBarWidget itself
//  gives the exact pixels the app draws, at 2x, every time.
//
//  Not a test: it asserts nothing, so it is named *-shot rather than *-test
//  and the suite runner leaves it alone.
//

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "docs/screenshots/menubar.png"

/// A believable afternoon: storage nearly full but not yet flagged, the
/// processor and memory busy enough to show the amber, the rest calm.
let readings: [MenuBarReading] = [
    MenuBarReading(label: "SSD", load: 0.87, value: "87%", severity: .ofDisk(0.87)),
    MenuBarReading(label: "GPU", load: 0.16, value: "16%"),
    MenuBarReading(label: "SEN", load: 0, value: "62°", severity: .ofTemperature(62)),
    MenuBarReading(label: "CPU", load: 0.61, value: "61%"),
    MenuBarReading(label: "RAM", load: 0.83, value: "83%", severity: .warning),
]
var network = MenuBarReading(label: "NET", value: "1.2 MB/s")
network.rates = {
    var pair = MenuBarReading.Pair("98 KB/s", "1.2 MB/s")
    pair.speeds = .init(upload: 98_000, download: 1_200_000)
    return pair
}()

func widget(_ styles: [MenuBarStyle], _ reading: MenuBarReading) -> MenuBarWidget {
    let w = MenuBarWidget()
    w.styles = styles
    w.content = reading
    w.frame.size = NSSize(width: max(1, w.intrinsicContentSize.width),
                          height: MenuBarMetrics.height)
    return w
}

let items = readings.map { widget([.mini], $0) } + [widget([.rates], network)]

/// macOS's dark menu bar over a dark wallpaper, near enough: the strip has
/// to read as a menu bar, not as a swatch of one of the palette's colours.
final class Bar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

let spacing: CGFloat = 14, margin: CGFloat = 12
let width = items.reduce(margin * 2) { $0 + $1.frame.width } + spacing * CGFloat(items.count - 1)
let bar = Bar(frame: NSRect(x: 0, y: 0, width: width, height: MenuBarMetrics.height))
bar.appearance = NSAppearance(named: .darkAqua)
var x = margin
for item in items {
    item.frame.origin = NSPoint(x: x, y: 0)
    bar.addSubview(item)
    x += item.frame.width + spacing
}

// 2x by hand: a cached-display bitmap otherwise comes back at 1x, which is
// soft on every screen a README is read on.
let scale: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(bar.bounds.width * scale),
                                 pixelsHigh: Int(bar.bounds.height * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = bar.bounds.size
bar.cacheDisplay(in: bar.bounds, to: rep)

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output) at \(rep.pixelsWide)x\(rep.pixelsHigh)")
