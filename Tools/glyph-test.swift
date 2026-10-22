//
//  glyph-test.swift
//
//  Holds the sidebar's tiles to the rules in Glyph.swift.
//
//  Run:  cat Roost/UI/Glyph.swift Roost/Views/SettingsSelection.swift \
//            Tools/glyph-test.swift | swift -
//
//  The tiles are what the eye scans the column by, and nothing about a bad
//  one fails: Storage and Disk shared one orange drive for as long as both
//  existed, and the only way to see it was to look at the sidebar. A symbol
//  missing on this system falls back to a generic tile just as quietly.
//
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// The modules a normal Mac lists under Monitoring, in registry order.
/// Battery has a tile -- the Overview's battery card uses it -- but no row.
let monitoring = ["CPU", "GPU", "RAM", "Disk", "Sensors", "Network"]

/// The sidebar's sections, top to bottom, as SettingsModel builds them.
let tools: [SettingsSelection.Tool] = SettingsSelection.Tool.allCases
let ungrouped: [String] = tools.filter { $0.group == nil }.map { $0.rawValue }
let top: [String] = ["Dashboard"] + ungrouped
var sections: [(String, [String])] = [("top", top)]
for group in SettingsSelection.Group.allCases {
    var rows: [String] = tools.filter { $0.group == group }.map { $0.rawValue }
    if group == .tools { rows += ["Search & switcher", "Clipboard"] }
    sections.append((group.rawValue, rows))
}
sections.append(("Monitoring", monitoring))

let rows: [String] = sections.flatMap(\.1)
let fallback = "circle.grid.2x2.fill"

print("every row has a tile of its own")
for row in rows {
    check("\(row) is not the fallback tile", Glyph.named(row).symbol != fallback)
}

print("\nno symbol on two rows")
var seen: [String: String] = [:]
for row in rows + ["Settings", "Battery"] {
    let symbol = Glyph.named(row).symbol
    if let other = seen[symbol] {
        check("\(row) and \(other) share \(symbol)", false)
    }
    seen[symbol] = row
}
check("\(seen.count) rows, \(seen.count) symbols", seen.count == rows.count + 2)

print("\nno colour twice under one heading")
for (heading, members) in sections {
    let colours: [Color] = members.map { Glyph.named($0).color }
    var distinct: [Color] = []
    for colour in colours where !distinct.contains(colour) { distinct.append(colour) }
    check("\(heading): \(members.count) rows, \(distinct.count) colours",
          distinct.count == members.count)
}

print("\nno two neighbouring rows in one colour")
for (above, below) in zip(rows, rows.dropFirst()) {
    check("\(above) / \(below)", Glyph.named(above).color != Glyph.named(below).color)
}

print("\noptical size")
for row in rows {
    let symbol = Glyph.named(row).symbol
    let scale = Glyph.opticalScale(of: symbol)
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 100, weight: .semibold)) else {
        check("\(row): \(symbol) exists", false)
        continue
    }
    let largest = max(image.size.width, image.size.height) / 100 * scale
    check("\(row) fits the limit (\(String(format: "%.2f", largest)))",
          largest <= Glyph.opticalLimit + 0.001)
}
// The scale only ever shrinks, and leaves an ordinary symbol alone.
check("cpu.fill is drawn at its own size", Glyph.opticalScale(of: "cpu.fill") == 1)
check("doc.on.doc.fill is brought down", Glyph.opticalScale(of: "doc.on.doc.fill") < 1)
check("a missing symbol is left at 1", Glyph.opticalScale(of: "no.such.symbol") == 1)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
