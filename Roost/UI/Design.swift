import SwiftUI
import AppKit

/// The measurements every page in the settings window is laid out with.
///
/// Written down once because they were written down everywhere: 18 for a
/// page's side inset, 44 for the title bar it scrolls under, 10 for a card's
/// corner and 12 for its text inset turned up as literals in every pane, so
/// one page drifting by two points was invisible until the two sat side by
/// side. `Controls` builds its AppKit cards from these and the SwiftUI
/// surfaces below use the same numbers, so a Dashboard card and a settings
/// card are the same object drawn twice.
enum RoostMetrics {
    /// A page's inset from the window's sides.
    /// The widest a settings column is allowed to get.
    ///
    /// A page pinned to the window's full width puts a switch a thousand
    /// points from the label it belongs to on an external display, and the
    /// eye cannot carry a row that far. 1000 is about the width at which a
    /// label, its caption and a control still read as one line; past that
    /// the row becomes two things at opposite ends of the screen.
    ///
    /// A maximum, not a fixed width: a narrow window gets the whole of
    /// itself, less the page inset.
    static let maxContentWidth: CGFloat = 1000

    static let pageInset: CGFloat = 18
    /// What the AppKit pages leave clear above their first section. They
    /// were written to clear the title bar themselves, but the detail column
    /// already starts below the toolbar, so the 44 they reserved came on top
    /// of it: measured from a render, the first heading sat 106pt down a
    /// 480pt window against the Dashboard's 60.
    static let pageTop: CGFloat = 44
    /// Where every page's content actually starts below the toolbar.
    static let contentTop: CGFloat = 8
    /// Between one section and the next.
    static let sectionSpacing: CGFloat = 18
    /// A card's corner. Continuous, as the system's own cards are.
    static let cardRadius: CGFloat = 10
    /// Text inside a card, from its edge.
    static let cardInset: CGFloat = 12
    /// Between cards in a grid. Less than between sections, so cards read as
    /// one group.
    static let gridSpacing: CGFloat = 12
    /// The tinted square behind a sidebar or section symbol.
    static let glyphTile: CGFloat = 20

    // The settings sidebar, named here so the rows cannot drift apart again
    // one hard-coded padding at a time. A 20pt tile with 3pt above and below
    // measured 34pt from row to row in a render -- the top of the range a
    // Mac sidebar sits in, and with seventeen rows it was the reason the
    // column scrolled at the default window height. An 18pt tile with 1pt
    // above and below measures 32pt, and the column fits.
    //
    // The gap above each group heading (about 37pt) is the sidebar list
    // style's own. `defaultMinListHeaderHeight` was tried and changed
    // nothing; closing it further would take offsets against the list's
    // layout, which break on the next release that changes it.
    static let sidebarGlyph: CGFloat = 18
    /// Between a row's tile and its name.
    static let sidebarRowSpacing: CGFloat = 8
    static let sidebarRowPadding: CGFloat = 1
    static let sidebarFooterHeight: CGFloat = 36
    /// Each footer icon's square hit area.
    static let sidebarFooterButton: CGFloat = 26
    /// Between footer buttons. With the 26pt hit areas, a 30pt pitch: the
    /// highlights of two neighbours never touch under a moving pointer.
    static let sidebarFooterSpacing: CGFloat = 4
    /// The footer's inset from the column's sides, and Support's inside its
    /// highlight: 8 and 8 put its heart 16pt in, on the column of the rows'
    /// tiles, measured in a render.
    static let sidebarFooterInset: CGFloat = 8
    /// The footer's symbols and Support's word. A size under the rows' 13,
    /// so the bar reads as quieter than the list above it.
    static let sidebarFooterSymbol: CGFloat = 12
    static let sidebarFooterLabel: CGFloat = 11
    static let sidebarFooterRadius: CGFloat = 7
}

// MARK: - Status

/// A state, said three ways at once: a colour, a symbol and a word.
///
/// The palette's three colours were validated for colour-vision separation,
/// and that is still not enough on its own -- a reading's state must survive
/// a greyscale screenshot, Increase Contrast, and somebody who simply does not
/// know what teal is meant to mean. So the symbol changes with the state as
/// well as the colour, and the word is always there.
enum StatusTone: Equatable {
    case calm, warning, critical, neutral

    init(_ severity: MenuBarReading.Severity) {
        switch severity {
        case .calm:     self = .calm
        case .warning:  self = .warning
        case .critical: self = .critical
        }
    }

    init(_ level: HealthLevel) {
        switch level {
        case .normal:    self = .calm
        case .elevated:  self = .warning
        case .attention: self = .critical
        }
    }

    var color: Color {
        switch self {
        case .calm:     return Color(nsColor: .roostCalm)
        case .warning:  return Color(nsColor: .roostWarning)
        case .critical: return Color(nsColor: .roostCritical)
        case .neutral:  return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .calm:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        case .neutral:  return "circle.dashed"
        }
    }
}

/// A small symbol-and-word label in a tone.
struct StatusBadge: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.color)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Surfaces

/// The card every grouped thing sits on.
///
/// The same fill and hairline `Controls`' AppKit card uses. Increase Contrast
/// turns the hairline into a full-strength separator, because a 45% border on
/// a 14% fill is exactly what that setting exists to get rid of; Reduce
/// Transparency gives it an opaque fill, since behind it is the window's
/// glass and the glass is what the user asked to see less of.
struct Surface: ViewModifier {
    var padding: CGFloat = RoostMetrics.cardInset
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RoostMetrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }

    private var fill: Color {
        // `withAlphaComponent`, not `.opacity`, and the difference was a
        // visible bug. `quaternaryLabelColor` carries its own alpha of about
        // 0.1; SwiftUI's `.opacity` multiplies that, so 0.14 of it landed at
        // 0.014 and the Dashboard's cards measured 1.04:1 against the window
        // -- a fill contributing nothing, the cards reading on their border
        // alone. `Card` in Controls.swift sets the alpha instead and measures
        // 1.49:1, and its comment says the two are meant to change together.
        // They did not; this is the one that was wrong.
        reduceTransparency ? Color(nsColor: .controlBackgroundColor)
                           : Color(nsColor: .quaternaryLabelColor.withAlphaComponent(0.14))
    }

    private var border: Color {
        contrast == .increased ? Color(nsColor: .separatorColor)
                               : Color(nsColor: .separatorColor).opacity(0.45)
    }
}

extension View {
    func surface(padding: CGFloat = RoostMetrics.cardInset) -> some View {
        modifier(Surface(padding: padding))
    }
}

/// A section's heading: a short title, and optionally a line saying what the
/// section is for.
struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Charts

/// A reading's recent history as a line over a faint fill.
///
/// No axis and no labels: on a card it answers "rising, falling or flat",
/// and the popup has the chart with numbers on it. Values are 0...1; a
/// mirror series is drawn as a second line in the upload colour, which is
/// the convention the menu bar's traffic chart and the Network popup use.
struct Sparkline: View {
    let values: [Double]
    var mirror: [Double]?
    var tint: Color = Color(nsColor: .roostCalm)
    var mirrorTint: Color = Color(nsColor: .roostWarning)
    /// Fixed so a card does not change height while history fills in.
    var height: CGFloat = 34

    var body: some View {
        Canvas { context, size in
            if let mirror, mirror.count > 1 {
                context.stroke(line(mirror, in: size), with: .color(mirrorTint), lineWidth: 1.25)
            }
            guard values.count > 1 else { return }
            var area = line(values, in: size)
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: x(for: 0, count: values.count, width: size.width),
                                     y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line(values, in: size), with: .color(tint), lineWidth: 1.5)
        }
        .frame(height: height)
        // The figures it is drawn from are on the card in words.
        .accessibilityHidden(true)
    }

    /// Right-aligned, so a short history grows in from the right the way
    /// the popups' charts do, instead of stretching two points across the
    /// whole width. Full width at half a minute: at a minute, as first
    /// written, a Dashboard opened just after launch showed a tick in the
    /// corner of each card.
    private func x(for index: Int, count: Int, width: CGFloat) -> CGFloat {
        let slots = max(count - 1, 1)
        let span = width * min(1, CGFloat(count - 1) / 29)
        return width - span + span * CGFloat(index) / CGFloat(slots)
    }

    private func line(_ series: [Double], in size: CGSize) -> Path {
        var path = Path()
        let inset: CGFloat = 1.5
        for (index, value) in series.enumerated() {
            let clamped = value.isFinite ? min(max(value, 0), 1) : 0
            let point = CGPoint(x: x(for: index, count: series.count, width: size.width),
                                y: inset + (size.height - inset * 2) * (1 - clamped))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// How full something is, as a bar in its severity's colour.
struct FillGauge: View {
    let fraction: Double
    let tone: StatusTone

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                Capsule().fill(tone.color)
                    .frame(width: geometry.size.width * min(max(fraction.isFinite ? fraction : 0, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Glyphs

/// The tinted square the sidebar puts beside each page, for use anywhere a
/// page is named -- a Dashboard card names the module it opens with the same
/// tile, so the two are recognisably the same thing.
struct GlyphTile: View {
    let glyph: Glyph
    var size: CGFloat = RoostMetrics.glyphTile
    /// One flat colour instead of the gradient. A column of fifteen tiles
    /// each lit from the top read as fifteen buttons; flat, they read as
    /// labels, and the names beside them carry the weight.
    var flat = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(flat ? AnyShapeStyle(glyph.color) : AnyShapeStyle(glyph.color.gradient))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: glyph.symbol)
                    .font(.system(size: size * 0.55 * Glyph.opticalScale(of: glyph.symbol),
                                  weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}
