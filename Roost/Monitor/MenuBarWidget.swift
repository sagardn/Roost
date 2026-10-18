import AppKit

/// What a module knows about itself, for whichever shapes are switched on.
///
/// One payload rather than one per shape. A module samples once and the menu
/// bar draws whatever it was asked for out of that, so turning on a second
/// shape costs a draw and never a second reading -- which is the mistake the
/// system this replaces made: each widget held its own reader.
///
/// A shape draws what it can and leaves out what is not there. A module with
/// no history gets an empty line chart rather than a crash, and one with no
/// per-core figures gets a single bar.
struct MenuBarReading: Equatable {

    /// One part of a load: user against system, download against upload.
    struct Segment: Equatable {
        let value: Double
        let color: NSColor

        init(_ value: Double, _ color: NSColor) {
            self.value = value
            self.color = color
        }
    }

    /// Three letters at most. The bar is narrow.
    var label: String

    /// 0...1. What the colour ramp and every proportional shape read.
    var load: Double

    /// Already formatted: only the module knows whether this is a
    /// percentage, a temperature or a rate.
    var value: String

    /// Whether the figure is worth flagging. nil reads it off `load` through
    /// the shared ramp, which is right for a processor. A module whose
    /// percentage is not its health says so here: memory 82% "used" is a
    /// healthy Mac caching files, and a disk 85% full is not urgent.
    var severity: Severity?

    enum Severity: Int, Comparable {
        case calm, warning, critical

        /// The ramp's zones: calm under 50%, warning to 80%, critical above.
        ///
        /// By the load, not by comparing the ramp's colour against the
        /// palette: the colours are the user's to choose, and two set to the
        /// same value made every warning read as critical.
        ///
        /// The thresholds live in `SeverityBands`, shared with everything
        /// else that steps on them.
        static func of(load: Double) -> Severity { of(load, on: .load) }

        /// A volume's own bands -- see `SeverityBands.disk`.
        static func ofDisk(_ used: Double) -> Severity { of(used, on: .disk) }

        /// Degrees Celsius -- see `SeverityBands.temperature`. The load ramp's
        /// 50% was 65 °C on a 30-100 scale, which flagged a machine doing
        /// ordinary work.
        static func ofTemperature(_ celsius: Double) -> Severity { of(celsius, on: .temperature) }

        static func of(_ value: Double, on bands: SeverityBands) -> Severity {
            Severity(rawValue: bands.zone(value)) ?? .calm
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var resolvedSeverity: Severity { severity ?? .of(load: load) }

    /// Recent history, oldest first. Empty is fine.
    var history: [Double] = []

    /// One entry per bar -- cores for a processor, a single bar otherwise.
    /// Empty falls back to one bar at `load`.
    var bars: [Double] = []

    /// What the load is made of, each 0...1 and summing to no more than
    /// `load`. Empty draws `load` as one segment.
    var segments: [Segment] = []

    /// Two short figures worth stacking -- used over free. nil where the
    /// module has only one number to report, and the shape that draws them
    /// is then not offered.
    var pair: Pair?

    /// Two rates, which get arrows: up over down, read over write.
    ///
    /// Separate from `pair` because storage wants both and they are not the
    /// same two numbers: used and free is what the disk holds, read and
    /// write is what it is doing. One field serving both would have put
    /// arrows on a capacity or a capacity under the rate shape.
    var rates: Pair?

    struct Pair: Equatable {
        let top: String
        let bottom: String
        /// How fast each rate is going, for a module whose rates are a
        /// link's: upload on top, download below. nil keeps them plain,
        /// which is what storage wants -- a busy disk is not news the way a
        /// saturated link is.
        var speeds: Speeds?

        init(_ top: String, _ bottom: String) {
            self.top = top
            self.bottom = bottom
        }
    }

    struct Speeds: Equatable {
        let upload: Double
        let download: Double
    }

    /// Two series on one scale, one mirrored against the other. Network, and
    /// nothing else: up and down are not two readings to stack, they are one
    /// reading with a direction.
    var mirrored: Mirrored?

    struct Mirrored: Equatable {
        let up: [Double]
        let down: [Double]
    }

    /// An SF Symbol to draw, for the icon shape. nil for every reading that
    /// is a number.
    var symbol: String?
    /// Drawn faded: the module is in the menu bar but not doing its job --
    /// clipboard history with capture switched off.
    var dimmed = false

    init(label: String, load: Double = 0, value: String = "", severity: Severity? = nil,
         history: [Double] = [], bars: [Double] = [], segments: [Segment] = [],
         pair: Pair? = nil, rates: Pair? = nil, mirrored: Mirrored? = nil,
         symbol: String? = nil, dimmed: Bool = false) {
        self.symbol = symbol
        self.dimmed = dimmed
        self.label = label
        self.load = load
        self.value = value
        self.severity = severity
        self.history = history
        self.bars = bars
        self.segments = segments
        self.pair = pair
        self.rates = rates
        self.mirrored = mirrored
    }

    /// Whether this reading can fill a given shape.
    ///
    /// Asked before a shape is drawn or measured, so a module that has only
    /// a figure cannot be made to draw a pair by a settings file edited by
    /// hand -- it takes no width and draws nothing rather than a blank slot.
    func canDraw(_ style: MenuBarStyle) -> Bool {
        switch style {
        case .pair:          return pair != nil
        case .rates:         return rates != nil
        case .trafficChart:  return mirrored != nil
        case .symbol:        return symbol != nil
        default:             return true
        }
    }
}

/// Draws a module's reading into a status item, in whichever shapes it is set
/// to.
///
/// Independent of the widget framework it replaces: that is fourteen view
/// classes behind a protocol, each with its own reader, settings pane, preview
/// and animation, and between them some four thousand lines. The six shapes
/// anybody actually chooses between are drawn here, from one sample, in one
/// view, in the same visual language -- a 7pt caption over a 12pt figure, and
/// the shared load ramp for every colour -- so a module switching to this is
/// not a visible change.
///
/// One view for all the shapes rather than one each. A module showing a
/// figure and a chart is two draws into one rect, not two views with two
/// frames to keep in step, and every shape of one module opens the same
/// popup, so there is nothing to hit-test between them.
final class MenuBarWidget: NSView {

    var content: MenuBarReading? {
        didSet {
            guard content != oldValue else { return }
            // Only when the width moved: a figure ticking between 9% and 10%
            // must not relayout the menu bar, and a chart advancing by one
            // sample must not either.
            if intrinsicContentSize != lastSize {
                lastSize = intrinsicContentSize
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }
    }

    /// The shapes drawn, left to right. Empty draws nothing, which is a
    /// choice a user can make.
    var styles: [MenuBarStyle] = [.mini] {
        didSet {
            guard styles != oldValue else { return }
            lastSize = intrinsicContentSize
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var lastSize: NSSize = .zero

    /// Redraws when a colour is changed in Settings. The reading does not
    /// change with it, so `content`'s equality check would otherwise keep
    /// the old colour on screen until the figure itself next moved.
    private var colourObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard colourObserver == nil else { return }
        colourObserver = NotificationCenter.default.addObserver(
            forName: RoostColors.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }

    deinit {
        if let colourObserver { NotificationCenter.default.removeObserver(colourObserver) }
    }

    private let captionFont = NSFont.systemFont(ofSize: 7, weight: .light)
    private let labelFont = NSFont.systemFont(ofSize: 7, weight: .regular)
    private let figureSize: CGFloat = 12
    private let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private let arrowWidth: CGFloat = 9

    // MARK: - Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: wanted, height: NSView.noIntrinsicMetric)
    }

    private var wanted: CGFloat {
        guard let reading = content else {
            // Before the first sample lands. Wide enough not to flicker when
            // it does.
            return styles.isEmpty ? 0 : MenuBarMetrics.figureWidth
        }
        // Nothing switched on is nothing drawn, and a zero-width item is how
        // the menu bar says so.
        guard !styles.isEmpty else { return 0 }
        let bars = max(1, reading.bars.count)
        return styles
            .filter { reading.canDraw($0) }
            .reduce(0) { $0 + MenuBarMetrics.width(of: $1, bars: bars) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let reading = content else { return }
        var x: CGFloat = 0
        let bars = max(1, reading.bars.count)
        for style in styles where reading.canDraw(style) {
            let width = MenuBarMetrics.width(of: style, bars: bars)
            draw(style, reading, in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width
        }
    }

    private func draw(_ style: MenuBarStyle, _ reading: MenuBarReading, in rect: NSRect) {
        let inner = rect.insetBy(dx: MenuBarMetrics.padding, dy: 0)
        switch style {
        case .label:      drawName(reading.label, in: inner)
        case .mini:       drawFigure(reading, in: rect)
        case .lineChart:  drawLineChart(reading, in: inner)
        case .barChart:   drawBarChart(reading, in: inner)
        case .pieChart:   drawRing(reading, in: inner)
        case .tachometer: drawGauge(reading, in: inner)
        case .pair:         drawPair(reading, in: inner, arrows: false)
        case .rates:        drawPair(reading, in: inner, arrows: true)
        case .trafficChart: drawTrafficChart(reading, in: inner)
        case .symbol:       drawSymbol(reading, in: inner)
        }
    }

    // MARK: - symbol

    /// The module's icon in the bar's own ink, as macOS draws its own status
    /// icons -- through a palette configuration, for the reason `drawPair`
    /// records: a symbol drawn directly is not a template, and set() on the
    /// colour does nothing.
    private func drawSymbol(_ reading: MenuBarReading, in rect: NSRect) {
        guard let name = reading.symbol else { return }
        let colour = reading.dimmed ? ink.withAlphaComponent(0.4) : ink
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: reading.label)?
            .withSymbolConfiguration(.init(pointSize: MenuBarMetrics.symbolPointSize, weight: .regular)
                .applying(.init(paletteColors: [colour]))) else { return }
        let size = image.size
        let box = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                         width: size.width, height: size.height)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    // MARK: - label

    /// The module's name down the bar, a letter per row.
    ///
    /// Vertical because horizontal would cost the width of a whole word in a
    /// place that is measured in single points. Three letters is what fits
    /// the bar's height at a legible size.
    private func drawName(_ name: String, in rect: NSRect) {
        let letters = Array(name.prefix(3).uppercased())
        guard !letters.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: ink,
            .paragraphStyle: style
        ]

        // Each letter is given a rect taller than its share of the bar and
        // centred on it, rather than a rect the height of the row. A row is
        // a third of sixteen points and a 7pt line box is eight, so a rect
        // that tight clips the tops and tails off every glyph -- which is
        // exactly what it did. The rects overlap; the glyphs, whose caps are
        // five points, do not.
        let rowHeight = MenuBarMetrics.drawHeight / 3
        let top = rect.midY + MenuBarMetrics.drawHeight / 2
        let box: CGFloat = 10
        for (index, letter) in letters.enumerated() {
            let centre = top - (CGFloat(index) + 0.5) * rowHeight
            (String(letter) as NSString).draw(
                in: NSRect(x: rect.minX, y: centre - box / 2 - 1,
                           width: rect.width, height: box),
                withAttributes: attributes)
        }
    }

    // MARK: - mini

    private func drawFigure(_ reading: MenuBarReading, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center

        (reading.label as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.height - 10, width: rect.width, height: 8),
            withAttributes: [.font: captionFont,
                             .foregroundColor: ink.withAlphaComponent(0.9),
                             .paragraphStyle: style])

        // Every figure in its severity's colour, calm included. Plain calm
        // figures were tried -- so an alarm would be the only colour on the
        // bar -- and dropped at the user's call: the colour is what makes
        // the bar Roost's rather than one more grey readout. The bands stay
        // per module (`Severity`), so a disk at 86% is calm teal rather than
        // the amber the shared ramp gave it, and the weight steps only for a
        // flagged figure, so two calm readings never look unrelated.
        //
        // Known cost: on a mid-tone wallpaper coloured text can read poorly
        // (red measured 1.01:1 on a green one).
        //
        // Stepped, exactly one of the three colours -- see `SeverityBands`
        // for the gradient that was tried and why it went.
        //
        // With colour switched off in Settings, the bar's own ink -- but the
        // weight still steps, so a flagged figure is still told apart.
        let severity = reading.resolvedSeverity
        let coloured = RoostColors.menuBarColoured
        let color: NSColor = !coloured ? ink
            : legible(severity == .critical ? .roostCritical
                      : severity == .warning ? .roostWarning : .roostCalm)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: figureSize,
                                     weight: severity == .calm ? .regular : .semibold),
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        if coloured { attributes[.shadow] = halo }
        (reading.value as NSString).draw(
            in: NSRect(x: rect.minX, y: 1, width: rect.width, height: figureSize + 1),
            withAttributes: attributes)
    }

    // MARK: - line chart

    /// History filled to the baseline, in a box.
    ///
    /// The box is not decoration: a filled chart with nothing around it reads
    /// as a solid blob at this size, and the outline is what gives the fill
    /// something to be a proportion of.
    private func drawLineChart(_ reading: MenuBarReading, in rect: NSRect) {
        let box = NSRect(x: rect.minX, y: rect.midY - MenuBarMetrics.drawHeight / 2,
                         width: rect.width, height: MenuBarMetrics.drawHeight)

        ink.withAlphaComponent(0.25).setStroke()
        let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 2, yRadius: 2)
        frame.lineWidth = 1
        frame.stroke()

        let values = reading.history
        guard values.count > 1 else { return }

        let band = LoadBand.of(reading.load.isFinite ? reading.load : 0)
        let inner = box.insetBy(dx: 1.5, dy: 1.5)
        let step = inner.width / CGFloat(values.count - 1)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: inner.minX, y: inner.minY))
        for (index, value) in values.enumerated() {
            path.line(to: NSPoint(x: inner.minX + CGFloat(index) * step,
                                  y: inner.minY + proportion(value) * inner.height))
        }
        path.line(to: NSPoint(x: inner.maxX, y: inner.minY))
        path.close()

        band.color.withAlphaComponent(0.45).setFill()
        path.fill()
        band.color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - bar chart

    /// One bar per core, each tinted by its own load.
    ///
    /// Per-bar colour rather than one accent for the lot, because the thing
    /// worth seeing at this size is the *shape* of the load -- the
    /// performance cluster pinned while the efficiency cluster idles -- and a
    /// single colour hides exactly that. The popup's core bars read the same
    /// way, from the same ramp.
    private func drawBarChart(_ reading: MenuBarReading, in rect: NSRect) {
        let values = reading.bars.isEmpty ? [reading.load] : reading.bars
        let height = MenuBarMetrics.drawHeight
        let bottom = rect.midY - height / 2

        let total = CGFloat(values.count) * MenuBarMetrics.barWidth
            + CGFloat(values.count - 1) * MenuBarMetrics.barGap
        // Centred, so a four-core bar chart is not jammed against the figure
        // beside it when the width floor is doing the work.
        var x = rect.minX + max(0, (rect.width - total) / 2)

        for value in values {
            let clamped = proportion(value)
            let track = NSRect(x: x, y: bottom, width: MenuBarMetrics.barWidth, height: height)
            ink.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

            // A floor of one point, so a core at nothing is still visibly a
            // core rather than a gap in the row.
            let filled = max(1, clamped * height)
            LoadBand.of(clamped).color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: bottom,
                                             width: MenuBarMetrics.barWidth, height: filled),
                         xRadius: 1, yRadius: 1).fill()

            x += MenuBarMetrics.barWidth + MenuBarMetrics.barGap
        }
    }

    // MARK: - pie chart

    /// A ring, split into the parts the load is made of.
    private func drawRing(_ reading: MenuBarReading, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let side = min(rect.width, MenuBarMetrics.drawHeight)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let lineWidth: CGFloat = max(2, side / 4)
        let radius = (side - lineWidth) / 2

        context.saveGState()
        context.setShouldAntialias(true)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)

        // The track first, so a quiet reading is still a ring and not an
        // empty space where one should be.
        context.setStrokeColor(ink.withAlphaComponent(0.18).cgColor)
        context.addArc(center: centre, radius: radius,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()

        // Clockwise from twelve o'clock, which is how a proportion of a
        // circle is read.
        var angle: CGFloat = .pi / 2
        for segment in segments(of: reading) {
            let sweep = proportion(segment.value) * .pi * 2
            guard sweep > 0.001 else { continue }
            context.setStrokeColor(segment.color.cgColor)
            context.addArc(center: centre, radius: radius,
                           startAngle: angle, endAngle: angle - sweep, clockwise: true)
            context.strokePath()
            angle -= sweep
        }
        context.restoreGState()
    }

    // MARK: - tachometer

    /// A half-gauge, filling left to right.
    private func drawGauge(_ reading: MenuBarReading, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let side = min(rect.width, MenuBarMetrics.drawHeight)
        let lineWidth: CGFloat = max(2, side / 4)
        let radius = (side - lineWidth) / 2
        // A half-gauge is all above its centre, so the centre sits low in the
        // rect and the arc uses the full height rather than half of it.
        let centre = CGPoint(x: rect.midX, y: rect.midY - radius / 2)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)

        // Clockwise, which with the y-up coordinate system means decreasing
        // angle: from π down to 0 is the half above the centre. Anticlockwise
        // takes the long way round and draws the half below it, which is the
        // half that is not there.
        context.setStrokeColor(ink.withAlphaComponent(0.18).cgColor)
        context.addArc(center: centre, radius: radius,
                       startAngle: .pi, endAngle: 0, clockwise: true)
        context.strokePath()

        var angle: CGFloat = .pi
        for segment in segments(of: reading) {
            let sweep = proportion(segment.value) * .pi
            guard sweep > 0.001 else { continue }
            context.setStrokeColor(segment.color.cgColor)
            context.addArc(center: centre, radius: radius,
                           startAngle: angle, endAngle: angle - sweep, clockwise: true)
            context.strokePath()
            angle -= sweep
        }
        context.restoreGState()
    }

    /// A reading mapped onto 0...1.
    ///
    /// Not merely clamped: NaN and infinity have to be caught here, because
    /// CoreGraphics does not ignore them -- a NaN coordinate in a path or an
    /// arc raises, which from inside `draw` is the whole app going down. A
    /// reader that divides by a zero denominator produces one, which is not
    /// hypothetical: it is what a rate reader returns on its first sample.
    private func proportion(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }

    /// What the ring and the gauge fill themselves with.
    ///
    /// A module that says how its load divides gets those parts; one that
    /// says only how busy it is gets a single band from the shared ramp, so
    /// the ring agrees with the figure beside it about what counts as busy.
    private func segments(of reading: MenuBarReading) -> [MenuBarReading.Segment] {
        if !reading.segments.isEmpty { return reading.segments }
        let load = reading.load.isFinite ? reading.load : 0
        return [.init(Double(proportion(load)), LoadBand.of(load).color)]
    }

    // MARK: - pair

    /// Two figures stacked.
    ///
    /// `arrows` is the difference between the two shapes that use this. A
    /// rate is going somewhere and the arrow says which way; memory is not,
    /// and an arrow beside "13.0 GB used" would be a lie about direction. The
    /// rows are the same either way, which is why one routine draws both.
    private func drawPair(_ reading: MenuBarReading, in rect: NSRect, arrows: Bool) {
        guard let pair = arrows ? reading.rates : reading.pair else { return }

        let style = NSMutableParagraphStyle()
        style.alignment = .right
        // The arrows carry the series colours again, amber up and indigo
        // down, matching the popup and its chart -- see drawFigure for why
        // the bar is coloured.
        let coloured = RoostColors.menuBarColoured
        let up = coloured ? legible(.roostAmber) : ink.withAlphaComponent(0.75)
        let down = coloured ? legible(.systemIndigo) : ink.withAlphaComponent(0.75)
        let rows: [(symbol: String, text: String, arrow: NSColor, figure: NSColor)]
        if arrows, let speeds = pair.speeds {
            rows = [("arrow.up", pair.top, up, RateTint.figure(speeds.upload, ink: ink)),
                    ("arrow.down", pair.bottom, down, RateTint.figure(speeds.download, ink: ink))]
        } else if arrows {
            rows = [("arrow.up", pair.top, up, ink), ("arrow.down", pair.bottom, down, ink)]
        } else {
            rows = [("", pair.top, ink, ink), ("", pair.bottom, ink, ink)]
        }
        let textLeft = arrows ? rect.minX + arrowWidth : rect.minX

        for (index, row) in rows.enumerated() {
            let y = index == 0 ? bounds.height / 2 - 1 : 1
            // Coloured through a palette configuration rather than by setting
            // a fill and drawing: a symbol image is not a template once it is
            // drawn directly, so `set()` did nothing and every arrow came out
            // black -- invisible on a dark bar, whatever colour was asked for.
            if arrows,
               let arrow = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold)
                    .applying(.init(paletteColors: [row.arrow]))) {
                let box = NSRect(x: rect.minX, y: y + 1, width: 7, height: 7)
                NSGraphicsContext.saveGraphicsState()
                if coloured { halo.set() }
                arrow.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
            }
            (row.text as NSString).draw(
                in: NSRect(x: textLeft, y: y, width: rect.maxX - textLeft, height: 11),
                withAttributes: [.font: speedFont,
                                 .foregroundColor: row.figure,
                                 .paragraphStyle: style])
        }
    }

    // MARK: - traffic chart

    /// Upload above the centre line, download below, on one shared scale.
    ///
    /// One scale for both, not one each: the point of looking at the two
    /// together is which is bigger, and a chart that rescaled each half
    /// independently would show a trickle of upload as tall as a full-rate
    /// download.
    private func drawTrafficChart(_ reading: MenuBarReading, in rect: NSRect) {
        guard let series = reading.mirrored else { return }

        let box = NSRect(x: rect.minX, y: rect.midY - MenuBarMetrics.drawHeight / 2,
                         width: rect.width, height: MenuBarMetrics.drawHeight)

        ink.withAlphaComponent(0.25).setStroke()
        let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 2, yRadius: 2)
        frame.lineWidth = 1
        frame.stroke()

        let inner = box.insetBy(dx: 1.5, dy: 1.5)
        let peak = max(series.up.max() ?? 0, series.down.max() ?? 0)
        guard peak > 0, inner.width > 0 else { return }

        let middle = inner.midY
        for (values, color, up) in [(series.up, NSColor.roostAmber, true),
                                    (series.down, NSColor.systemIndigo, false)] {
            guard values.count > 1 else { continue }
            let step = inner.width / CGFloat(values.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inner.minX, y: middle))
            for (index, value) in values.enumerated() {
                let share = value.isFinite ? CGFloat(min(max(value / peak, 0), 1)) : 0
                let height = share * (inner.height / 2)
                path.line(to: NSPoint(x: inner.minX + CGFloat(index) * step,
                                      y: up ? middle + height : middle - height))
            }
            path.line(to: NSPoint(x: inner.maxX, y: middle))
            path.close()
            color.withAlphaComponent(0.55).setFill()
            path.fill()
        }

        ink.withAlphaComponent(0.3).setStroke()
        let centre = NSBezierPath()
        centre.move(to: NSPoint(x: inner.minX, y: middle))
        centre.line(to: NSPoint(x: inner.maxX, y: middle))
        centre.lineWidth = 0.5
        centre.stroke()
    }

    /// A picture of one shape, for somewhere that wants an illustration
    /// rather than a live reading -- the first-run window's fake menu bar.
    ///
    /// Drawn from the real renderer rather than shipped as an asset, so a
    /// preview cannot come to disagree with what the menu bar actually does.
    /// Template, so it takes the colour of whatever it is put on.
    static func preview(_ style: MenuBarStyle, label: String, load: Double) -> NSImage? {
        let widget = MenuBarWidget()
        widget.styles = [style]
        widget.content = MenuBarReading(
            label: label, load: load,
            value: "\(Int((load * 100).rounded()))%",
            // Enough of a curve and a spread to show what the shape is.
            history: (0..<40).map { load * (0.55 + 0.45 * sin(Double($0) / 5)) },
            bars: (0..<8).map { load * (0.4 + Double($0 % 4) / 5) },
            pair: .init("13.0 GB", "3.0 GB"),
            // The preview has to fill every field a shape can ask for, or
            // `canDraw` refuses the shape, it measures zero wide, and the
            // preview comes back blank -- which is what the first-run
            // window's Network entry was, silently, because only `pair` was
            // set and the rate shapes read `rates`.
            rates: .init("1.2 MB/s", "340 KB/s"),
            mirrored: .init(up: (0..<30).map { _ in Double.random(in: 0...load) },
                            down: (0..<30).map { _ in Double.random(in: 0...1) }))
        let width = max(1, widget.intrinsicContentSize.width)
        widget.frame = NSRect(x: 0, y: 0, width: width, height: MenuBarMetrics.height)

        guard let rep = widget.bitmapImageRepForCachingDisplay(in: widget.bounds)
        else { return nil }
        widget.cacheDisplay(in: widget.bounds, to: rep)
        let image = NSImage(size: widget.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The menu bar's own ink. Resolved per draw, because the bar flips with
    /// the wallpaper behind it, not only with the system appearance.
    private var ink: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white : .black
    }

    // MARK: - Legibility

    /// A palette colour made readable on the menu bar, whatever the
    /// wallpaper behind it.
    ///
    /// The palette was validated against the popups' solid surfaces, not
    /// against a wallpaper. On a mid-green one (#54733D) the colours measured
    /// 1.0 to 1.7:1 -- the same brightness as the bar, so the figures
    /// dissolved into it. Moved toward the bar's own ink by 40%, they keep
    /// their hue and reach 2.0 (red) to 2.7:1 (amber) there -- still short of
    /// text contrast on their own, so the halo does the rest.
    /// Applied to whatever the user picked in Settings, so a custom colour
    /// gets the same treatment rather than a hand-tuned exception.
    private func legible(_ color: NSColor) -> NSColor {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return resolved.blended(withFraction: MenuBarMetrics.legibleLift,
                                of: ink.usingColorSpace(.sRGB) ?? ink) ?? resolved
    }

    /// A soft shadow in the opposite of the ink, under coloured marks only.
    ///
    /// The trick macOS uses for desktop icon labels: a lightened colour alone
    /// cannot clear a busy or mid-tone wallpaper, but a 2pt dark halo gives
    /// every glyph an edge of its own to be read against. Not under plain
    /// ink, which the system already draws legibly.
    private var halo: NSShadow {
        let shadow = NSShadow()
        let dark = ink == .white
        shadow.shadowColor = (dark ? NSColor.black : .white).withAlphaComponent(dark ? 0.55 : 0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return shadow
    }
}

/// How bright a link's rate is drawn in the menu bar: dim when idle, full
/// when busy, and no hue.
///
/// Colour was tried twice -- red and green, then the popup's amber and
/// indigo -- and measured 1.0 to 2.1:1 against a green wallpaper. A menu bar
/// sits on whatever the wallpaper is, so a hue cannot be relied on there;
/// brightness, in the bar's own colour, can.
///
/// Logarithmic, because traffic is: an idle machine trickles a few KB/s and
/// a download runs at tens of MB/s, and on a linear scale everything short
/// of a big download would sit at the faint end. 1 KB/s and below is the
/// floor and 10 MB/s the ceiling -- four decades, so each tenfold step moves
/// a quarter of the way.
enum RateTint {
    static let floor: Double = 1_000
    static let ceiling: Double = 10_000_000
    /// How bright an idle figure is. The system draws its own secondary menu
    /// bar text at about this, so idle reads as idle without becoming hard
    /// to read.
    static let idleOpacity: Double = 0.6

    /// 0 at the floor, 1 at the ceiling.
    static func intensity(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond.isFinite, bytesPerSecond > floor else { return 0 }
        let share = log10(bytesPerSecond / floor) / log10(ceiling / floor)
        return min(max(share, 0), 1)
    }

    static func figure(_ bytesPerSecond: Double, ink: NSColor) -> NSColor {
        ink.withAlphaComponent(CGFloat(idleOpacity + (1 - idleOpacity) * intensity(bytesPerSecond)))
    }
}
