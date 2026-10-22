import SwiftUI
import AppKit

/// One tinted tile per row, the way System Settings labels its own sidebar.
///
/// This replaces the modules' bundled bitmap icons: they were flat monochrome
/// PNGs of varying weight drawn at whatever size they happened to be, so the
/// column never lined up and nothing distinguished one row from the next but
/// the word beside it. SF Symbols are vector, come in matching weights, follow
/// the system font metrics, and pick up the colour per module -- which is what
/// makes a ten-row sidebar scannable.
///
/// Its own file so `glyph-test` can hold the table to the rules below without
/// compiling the window around it.
struct Glyph {
    let symbol: String
    let color: Color

    /// The first symbol the running system actually has. SF Symbol names come
    /// and go between releases, so a missing one would otherwise render as a
    /// blank tile.
    private static func available(_ names: [String]) -> String {
        for name in names where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return "circle.grid.2x2"
    }

    // Held by `glyph-test` to three rules: no colour twice under one
    // heading, no two neighbouring rows in one colour, and no symbol on two
    // rows. Only the last was ever broken, and it was the one that mattered:
    // Storage and Disk were the same orange drive, so the page about what
    // fills the disk and the module that measures it were one tile. A colour
    // does come back under another heading -- eighteen rows and a dozen
    // system colours that read under a white symbol leave no choice -- and
    // where it does, the symbol is what tells the two apart.
    static func named(_ id: String) -> Glyph {
        switch id {
        case "Dashboard":
            return Glyph(symbol: available(["square.grid.2x2.fill"]), color: .indigo)
        case "Settings":
            return Glyph(symbol: available(["gearshape.fill"]), color: .gray)
        case "Check-up":
            return Glyph(symbol: available(["stethoscope", "heart.text.square.fill"]), color: .green)
        // A pie, not a drive: the page is what the space is taken by, and the
        // drive is Disk's, which measures the drive itself.
        case "Storage":
            return Glyph(symbol: available(["chart.pie.fill", "chart.pie"]), color: .orange)
        case "AI tools":
            return Glyph(symbol: available(["sparkles"]), color: .pink)
        case "Large files":
            return Glyph(symbol: available(["doc.viewfinder.fill", "doc.fill"]), color: .indigo)
        case "Duplicates":
            return Glyph(symbol: available(["doc.on.doc.fill"]), color: .teal)
        case "Space map":
            return Glyph(symbol: available(["square.grid.3x3.square", "square.grid.3x3.fill"]), color: .blue)
        case "Uninstaller":
            return Glyph(symbol: available(["xmark.bin.fill", "trash.fill"]), color: .red)
        case "Background items":
            return Glyph(symbol: available(["gearshape.2.fill"]), color: .gray)
        case "macOS protections":
            return Glyph(symbol: available(["checkmark.shield.fill", "lock.shield.fill"]), color: .mint)
        case "Search & switcher":
            return Glyph(symbol: available(["magnifyingglass"]), color: .purple)
        case "CPU":
            return Glyph(symbol: available(["cpu.fill", "cpu"]), color: .blue)
        case "GPU":
            return Glyph(symbol: available(["display", "tv"]), color: .purple)
        case "RAM":
            return Glyph(symbol: available(["memorychip.fill", "memorychip"]), color: .green)
        case "Disk":
            return Glyph(symbol: available(["internaldrive.fill", "internaldrive"]), color: .orange)
        case "Sensors":
            return Glyph(symbol: available(["thermometer.medium", "thermometer"]), color: .red)
        case "Network":
            return Glyph(symbol: available(["network"]), color: .teal)
        case "Battery":
            return Glyph(symbol: available(["battery.100percent", "battery.100"]), color: .green)
        case "Clipboard":
            return Glyph(symbol: available(["doc.on.clipboard.fill", "doc.on.clipboard"]), color: .cyan)
        default:
            return Glyph(symbol: available(["circle.grid.2x2.fill"]), color: .secondary)
        }
    }

    // MARK: - Optical size

    /// The most a symbol's larger side may be, as a multiple of the point
    /// size it is drawn at.
    ///
    /// SF Symbols share a cap height, not a box. Measured at 100pt semibold,
    /// most of the sidebar's symbols are 110-130 on their larger side, but
    /// doc.on.doc and doc.on.clipboard are 150 tall, stethoscope and
    /// gearshape.2 155 wide and battery 174 -- so at one font size Duplicates,
    /// Clipboard and Memory ran to the edges of their tiles while CPU sat
    /// well inside its own. 1.3 is the top of the ordinary range: the symbols
    /// already inside it are left alone, and only the outliers come down.
    static let opticalLimit: CGFloat = 1.3

    private static var scales: [String: CGFloat] = [:]

    /// What to multiply a symbol's point size by so it fills its tile as much
    /// as its neighbours do. 1 for most; measured once per symbol, because
    /// a sidebar redraw asks for every row's.
    static func opticalScale(of symbol: String) -> CGFloat {
        if let known = scales[symbol] { return known }
        let probe: CGFloat = 100
        var scale: CGFloat = 1
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: probe, weight: .semibold)) {
            let largest = max(image.size.width, image.size.height) / probe
            scale = min(1, opticalLimit / largest)
        }
        scales[symbol] = scale
        return scale
    }
}
