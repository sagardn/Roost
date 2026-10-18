#!/usr/bin/env swift
//
//  Draws the Roost icon: a roof over three rising bars.
//
//  A roost is where a bird comes home to, high up -- which is where this app
//  lives, at the top of the screen. So the mark is a roof, and under it the
//  thing the app keeps watch over: readings, as bars. The tallest is amber,
//  the colour a figure in the menu bar turns when it climbs, so the icon shows
//  the app doing its job rather than naming it. No bird: the old icon was one,
//  and the name it illustrated has gone.
//
//  Three concepts were drawn and compared at 256, 64, 32 and 16 pixels: a
//  house traced by a reading line, a roof formed by the peak of a pulse, and
//  this. The traced house turned into a thin generic outline at 32; the pulse
//  read as a caret, not a home. Only this one kept both of its halves at
//  16 pixels, which is the size an icon is read at most.
//
//  The plate is the app's own teal, #0E9BA8 -- the colour a calm reading is
//  drawn in, already validated for contrast and colour-vision deficiency in
//  Palette.swift -- so the icon and the menu bar agree.
//
//  Run it from anywhere -- paths are resolved from this file's own location:
//
//      swift Tools/makeicon.swift
//
//  It writes the app's icon set:
//
//      Roost/.../Assets.xcassets/AppIcon.appiconset
//
//  Everything is drawn in unit coordinates and scaled, so every size in the set
//  is rendered natively rather than resampled from one big PNG, and the small
//  sizes can thicken what would otherwise turn to mush.
//
import AppKit

// MARK: - palette

/// Roost's own colours. `skyMid` is #0E9BA8 exactly -- the calm colour from
/// `Palette.swift`, not an approximation.
let skyTop    = NSColor(srgbRed: 0.23, green: 0.80, blue: 0.85, alpha: 1)   // lifted #0E9BA8
let skyMid    = NSColor(srgbRed: 0x0E / 255, green: 0x9B / 255, blue: 0xA8 / 255, alpha: 1)
let skyBottom = NSColor(srgbRed: 0.02, green: 0.21, blue: 0.29, alpha: 1)   // deep teal, not navy
let markColor = NSColor.white
/// Lighter than the menu bar's warning amber, #CE7C00. Measured against the
/// plate behind the bar, from its foot to its top, #CE7C00 has a luminance
/// contrast of 1.84 down to 1.04 -- the top of the bar was the plate's own
/// brightness, held apart by hue alone. This is 2.79 to 1.46.
let peakColor = NSColor(srgbRed: 0xF2 / 255, green: 0xA1 / 255, blue: 0x1F / 255, alpha: 1)

// MARK: - the plate

/// The macOS icon shape is a superellipse -- continuous curvature into the
/// corners -- not a rounded rectangle, which reads visibly pinched next to the
/// system icons it sits beside.
func squircle(in r: NSRect, n: CGFloat = 4.7) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

// MARK: - the glyph

/// Roof and bars, in unit coordinates inside the icon plate.
///
/// `detailed` is false below 24 pixels, where the roof is thickened: at the
/// large sizes' weight it is under a pixel and a half at 16, and anti-aliases
/// into the plate.
func drawGlyph(in r: NSRect, detailed: Bool) {
    let s = r.width
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }

    // The roof. Round caps and join: a mitred peak this thick is a spike.
    let roof = NSBezierPath()
    roof.lineWidth = (detailed ? 0.075 : 0.10) * s
    roof.lineCapStyle = .round
    roof.lineJoinStyle = .round
    roof.move(to: p(0.20, 0.54))
    roof.line(to: p(0.50, 0.78))
    roof.line(to: p(0.80, 0.54))
    markColor.setStroke()
    roof.stroke()

    // The bars share a baseline and rise left to right, as a reading does in
    // the order people read. The gaps are as wide as a third of a bar, so
    // they survive at 32 pixels. The tallest stops 0.05 short of the roof's
    // inner edge: at 0.36 it touched it, and a bar holding up the roof is a
    // different picture from one sheltered under it.
    let bars: [(x: CGFloat, height: CGFloat, color: NSColor)] = [
        (0.285, 0.13, markColor), (0.440, 0.21, markColor), (0.595, 0.29, peakColor),
    ]
    for bar in bars {
        let rect = NSRect(x: r.minX + bar.x * s, y: r.minY + 0.22 * s,
                          width: 0.12 * s, height: bar.height * s)
        bar.color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22).fill()
    }
}

// MARK: - rendering

/// Renders at exact pixel dimensions.
///
/// NSImage.lockFocus() draws into a context at the screen's backing scale, so
/// on a Retina display every size came out twice as large as asked for and the
/// asset catalog rejected the whole set. Drawing into an explicitly sized
/// bitmap rep, with its size in points equal to its size in pixels, pins it to
/// 1x.
func makeIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // Apple's grid: the plate is 824/1024 of the canvas, centred, with the
    // margin left to the shadow.
    let side = size * 0.8047
    let rect = NSRect(x: (size - side) / 2, y: (size - side) / 2 + size * 0.010,
                      width: side, height: side)
    let shape = squircle(in: rect)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.014)
    shadow.shadowBlurRadius = size * 0.028
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [skyTop, skyMid, skyBottom], atLocations: [0, 0.46, 1], colorSpace: .sRGB)!
        .draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // light falling from the top, rather than the old gloss ellipse
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.15), NSColor.white.withAlphaComponent(0)],
               atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
              angle: -90)
    drawGlyph(in: rect, detailed: size >= 24)
    NSGraphicsContext.restoreGraphicsState()

    // hairline rim, so the edge stays crisp against a light wallpaper
    if size >= 24 {
        let rim = squircle(in: rect.insetBy(dx: size * 0.002, dy: size * 0.002))
        rim.lineWidth = size * 0.004
        NSColor.white.withAlphaComponent(0.16).setStroke()
        rim.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ size: CGFloat, to path: String) {
    guard let png = makeIcon(size: size).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to render \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("failed to write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - write both sets

// Tools/makeicon.swift -> the repository root
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // repo

// The merged app's asset catalog. The " 1" names are the second entry for a
//    size that the catalog lists at both 1x and 2x; they have to stay as Xcode
//    named them.
let appicon = root
    .appendingPathComponent("Roost/Supporting Files/Assets.xcassets/AppIcon.appiconset").path

let appiconVariants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),        ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),        ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),     ("icon_256x256 1.png", 256),
    ("icon_256x256.png", 256),     ("icon_512x512 1.png", 512),
    ("icon_512x512.png", 512),     ("icon_512x512@2x.png", 1024),
]
for (name, size) in appiconVariants { write(size, to: "\(appicon)/\(name)") }
print("wrote AppIcon.appiconset (\(appiconVariants.count) sizes)")
