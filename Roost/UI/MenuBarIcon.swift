import AppKit

/// Roost's mark, drawn small enough for the menu bar.
///
/// It stands in for the app itself, and the only place it appears is the status
/// item that shows up while monitoring is paused — there is no reading to draw,
/// so the app says who is still there and gives the user something to click.
///
/// The geometry is the app icon's, from `Tools/makeicon.swift`: a roof over
/// three rising bars. What changes is weight -- every stroke is thicker in
/// proportion, because 0.075 of 16pt is just over a point and disappears into
/// anti-aliasing on a 1x display -- and colour. A menu bar image is a template,
/// which means one colour, and macOS inverts it for a dark bar and dims it when
/// the app is hidden. Drawing in `NSColor.textColor` instead would have missed
/// both. With one colour the amber bar is just the tallest, which is still the
/// picture: readings, sheltered.
enum MenuBarIcon {

    /// 16×16, the size of a menu bar glyph beside 12pt text.
    static let size = CGSize(width: 16, height: 16)

    /// Made once. The image never changes — the template flag is what makes it
    /// follow the menu bar — so redrawing it per status-item update would be
    /// paying a bezier fill for the same pixels.
    static let image: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Roost"
        return image
    }()

    private static func draw(in rect: NSRect) {
        let s = rect.width
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }

        NSColor.black.setFill()
        NSColor.black.setStroke()

        // The icon's plate has padding the menu bar does not, so the mark is
        // spread to the full 16pt: the roof's ends sit at the edges and the
        // bars on the baseline.
        let roof = NSBezierPath()
        roof.lineWidth = 0.12 * s
        roof.lineCapStyle = .round
        roof.lineJoinStyle = .round
        roof.move(to: p(0.06, 0.56))
        roof.line(to: p(0.50, 0.94))
        roof.line(to: p(0.94, 0.56))
        roof.stroke()

        // In whole points -- 2 wide, 2 apart, 3, 5 and 7 tall from y = 1 -- so
        // at 1x every edge is a pixel edge and no gap is lost to
        // anti-aliasing. The tallest clears the roof's underside by 1.4pt.
        for (x, height) in [(3, 3), (7, 5), (11, 7)] as [(CGFloat, CGFloat)] {
            let bar = NSRect(x: rect.minX + x / 16 * s, y: rect.minY + s / 16,
                             width: 2 / 16 * s, height: height / 16 * s)
            NSBezierPath(roundedRect: bar, xRadius: 0.03 * s, yRadius: 0.03 * s).fill()
        }
    }
}
