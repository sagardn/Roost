import AppKit

// The pieces every popup is built from beyond the basic rows in
// PopupSection: a verdict line, a share bar, a two-sided traffic chart, and
// a fold for the details nobody needs twice.
//
// One vocabulary on purpose. Each popup used to be a column of section
// headers over label/value rows, which made them long, and made the answer
// to "is anything wrong" a matter of reading every row. They now all open
// the same way -- a one-line verdict, the headline figures, a picture of
// the reading -- so learning one popup is learning all of them.

// MARK: - Severity colour

extension MenuBarReading.Severity {
    /// The same three colours the menu bar flags with, so a popup's verdict
    /// can never disagree with the item it was opened from.
    var tint: NSColor {
        switch self {
        case .calm:     return .roostCalm
        case .warning:  return .roostWarning
        case .critical: return .roostCritical
        }
    }
}

/// Words for a 0...1 load, shared by every popup that measures one.
enum StatusWords {
    /// Below this the processor is doing nothing worth naming. Five percent
    /// is what an M-series Mac shows with only the menu bar and a terminal
    /// open; "Light load" for that overstated it.
    static let idleBelow = 0.05

    /// Changes at the same points as the colour, which comes from
    /// `Severity.of(load:)`: a word that said "Busy" over a calm dot, or the
    /// other way round, would be the popup arguing with itself.
    static func load(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        if fraction < idleBelow { return localized("Idle") }
        switch MenuBarReading.Severity.of(load: fraction) {
        case .calm:     return localized("Light load")
        case .warning:  return localized("Busy")
        case .critical: return localized("Heavy load")
        }
    }

    /// Where calm stops reading as "plenty". The colour stays teal to 90%,
    /// on purpose -- see `SeverityBands.disk` -- but "Plenty of room" over a
    /// disk 87% full was read, correctly, as the popup contradicting its own
    /// figure. Three quarters is where the word stops claiming plenty.
    static let fillingUpFrom = 0.75

    /// The disk's verdict. The colour still changes at exactly the disk
    /// bands; the word adds one step inside calm rather than moving them,
    /// because "Filling up" over a teal dot is a nuance, where "Getting full"
    /// over one would be the argument `load` above avoids.
    static func disk(_ used: Double) -> String {
        guard used.isFinite else { return "—" }
        switch MenuBarReading.Severity.ofDisk(used) {
        case .calm:     return used < fillingUpFrom ? localized("Plenty of room")
                                                    : localized("Filling up")
        case .warning:  return localized("Getting full")
        case .critical: return localized("Almost full")
        }
    }
}

// MARK: - Status line

/// "● Online · Wi-Fi · 64 ms": the answer to the question a popup is usually
/// opened for, in one line, with the word that answers it in full colour and
/// everything else secondary.
final class StatusLine: NSView {

    private let dot = Dot()
    private let text = NSTextField(labelWithString: "—")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(text)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ word: String, tint: NSColor, details: [String]) {
        dot.color = tint
        let line = NSMutableAttributedString(
            string: ([word] + details).joined(separator: " · "),
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        line.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                            .foregroundColor: NSColor.labelColor],
                           range: NSRange(location: 0, length: (word as NSString).length))
        text.attributedStringValue = line
    }

    private final class Dot: NSView {
        var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 8),
                heightAnchor.constraint(equalToConstant: 8)
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // Drawn rather than a layer colour, so the shade follows a switch
        // between light and dark without being told.
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

// MARK: - Headline

/// The two big figures side by side, at the full content width.
func headlinePair(_ left: NSView, _ right: NSView) -> NSView {
    let pair = NSStackView(views: [left, right])
    pair.distribution = .fillEqually
    pair.translatesAutoresizingMaskIntoConstraints = false
    pair.widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth).isActive = true
    return pair
}

// MARK: - Share bar

/// A rounded bar split into coloured shares of a whole, the rest left as
/// track.
///
/// For readings that are a share of something fixed: a disk's capacity, the
/// machine's memory. A history chart of either was a flat line -- capacity
/// moves in hours -- and spent ninety points of height saying "86%".
final class ShareBar: NSView {

    struct Segment {
        let fraction: Double
        let color: NSColor
    }

    var segments: [Segment] = [] { didSet { needsDisplay = true } }

    init(height: CGFloat = 8, width: CGFloat = PopupMetrics.contentWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        track.fill()

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x: CGFloat = 0
        for segment in segments {
            let fraction = segment.fraction.isFinite ? min(max(segment.fraction, 0), 1) : 0
            let width = bounds.width * CGFloat(fraction)
            guard width > 0 else { continue }
            segment.color.setFill()
            // A one-point gap between neighbours, so two shares of similar
            // colour still read as two.
            NSRect(x: x, y: 0, width: max(width - 1, 1), height: bounds.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Traffic chart

/// One series above the centre line, one below, each on its own scale, with
/// the peaks in a legend underneath.
///
/// Not the shared `TrafficChart`, whose two sides share one scale. On one
/// scale the smaller side is a flat line: a home connection's upload runs a
/// tenth of its download, and a disk reads in bursts its writes never reach
/// -- 696 KB/s of upload drew as nothing under an 8.9 MB/s download. With a
/// scale each, both show their shape, and the legend carries the magnitudes.
/// That is also why the peaks moved out of the plot: printed inside it, the
/// tallest spike was always drawn straight through its own label.
final class SplitTrafficChart: NSView {

    var upper: [Double] = [] { didSet { needsDisplay = true } }
    var lower: [Double] = [] { didSet { needsDisplay = true } }

    // Looked up on every draw rather than kept: the upper series is the
    // warning colour, which Settings can change while the popup is open.
    private let upperOverride: NSColor?
    private let lowerOverride: NSColor?
    private var upperTint: NSColor { upperOverride ?? .roostAmber }
    private var lowerTint: NSColor { lowerOverride ?? .systemIndigo }

    /// Floor on each scale, so an idle link or disk does not magnify a few
    /// stray bytes into a mountain range.
    private let minimumCeiling: Double = 64 * 1024

    init(upper: NSColor? = nil, lower: NSColor? = nil, height: CGFloat = 84) {
        upperOverride = upper
        lowerOverride = lower
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let area = bounds.insetBy(dx: 4, dy: 5)
        let middle = area.midY.rounded()

        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: area.minX, y: middle, width: area.width, height: 1)).fill()

        series(upper, upperTint, up: true, in: area, middle: middle)
        series(lower, lowerTint, up: false, in: area, middle: middle)
    }

    private func series(_ values: [Double], _ tint: NSColor, up: Bool,
                        in area: NSRect, middle: CGFloat) {
        guard values.count > 1 else { return }
        let peak = max(values.max() ?? 0, minimumCeiling)
        let step = area.width / CGFloat(values.count - 1)
        let reach = area.height / 2 - 1
        let base = up ? middle + 1 : middle

        func point(_ index: Int) -> NSPoint {
            let value = values[index].isFinite ? values[index] : 0
            let offset = CGFloat(min(max(value / peak, 0), 1)) * reach
            return NSPoint(x: area.minX + CGFloat(index) * step,
                           y: up ? base + offset : base - offset)
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: area.minX, y: base))
        for index in values.indices { fill.line(to: point(index)) }
        fill.line(to: NSPoint(x: area.maxX, y: base))
        fill.close()
        tint.withAlphaComponent(0.3).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        line.move(to: point(0))
        for index in values.indices.dropFirst() { line.line(to: point(index)) }
        tint.setStroke()
        line.stroke()
    }
}

/// The two peaks under a `SplitTrafficChart`, upper side on the left.
final class PeakLegend: NSView {

    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")
    private let upperName: String
    private let lowerName: String
    private let upperOverride: NSColor?
    private let lowerOverride: NSColor?
    private var upperTint: NSColor { upperOverride ?? .roostAmber }
    private var lowerTint: NSColor { lowerOverride ?? .systemIndigo }

    /// `upperName` and `lowerName` name the series -- "write", "read" --
    /// where the arrow alone would not say which is which.
    init(upperName: String = "", lowerName: String = "",
         upper: NSColor? = nil, lower: NSColor? = nil) {
        self.upperName = upperName
        self.lowerName = lowerName
        upperOverride = upper
        lowerOverride = lower
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for field in [left, right] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        right.alignment = .right
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 12),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            right.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(upper: Double, lower: Double) {
        left.attributedStringValue = Self.line("↑", upperName, upper, upperTint)
        right.attributedStringValue = Self.line("↓", lowerName, lower, lowerTint)
    }

    private static func line(_ arrow: String, _ name: String, _ peak: Double,
                             _ tint: NSColor) -> NSAttributedString {
        let line = NSMutableAttributedString(string: arrow + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: tint
        ])
        let words = (name.isEmpty ? "" : name + " ") + "peak " + Readings.rate(peak)
        line.append(NSAttributedString(string: words, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return line
    }
}

// MARK: - Details fold

/// "▸ More details", folding away the rows that are looked up once and then
/// never again: a MAC address, a mount point, a model name.
///
/// Remembers whether it was left open, per popup, so somebody who wants the
/// details does not have to ask for them on every open.
final class DisclosureButton: NSView {

    /// Called with the new state on every click, after `rows` have been
    /// shown or hidden. For rows with conditions of their own -- a Wi-Fi
    /// channel off Wi-Fi -- the popup re-applies those here.
    var onToggle: ((Bool) -> Void)?

    private(set) var isOpen: Bool
    private var rows: [NSView] = []
    private let key: String
    private let button = NSButton()

    init(title: String = "More details", key: String) {
        self.key = key
        isOpen = UserDefaults.standard.bool(forKey: key)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.title = localized(title)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 22),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateChevron()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds the button and then the rows it folds to `stack`, in that order.
    func install(in stack: NSStackView, rows: [NSView]) {
        self.rows = rows
        stack.addArrangedSubview(self)
        for row in rows {
            row.isHidden = !isOpen
            stack.addArrangedSubview(row)
        }
    }

    private func updateChevron() {
        button.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        // The chevron is the only thing saying whether the rows are out, and
        // it is a picture; VoiceOver hears it as the button's expanded state.
        button.setAccessibilityExpanded(isOpen)
    }

    @objc private func clicked() {
        isOpen.toggle()
        UserDefaults.standard.set(isOpen, forKey: key)
        updateChevron()
        rows.forEach { $0.isHidden = !isOpen }
        onToggle?(isOpen)
    }
}

// MARK: - The next step

/// A quiet link at the foot of a popup, for the one thing worth doing next.
///
/// Only where a reading has an obvious remedy, and only while it does: a
/// disk filling up has a cleaner, a Mac that is offline has its network
/// settings. A link on every popup at all times is a footer nobody reads;
/// one that appears when the verdict above it changes is the verdict
/// finishing its sentence.
final class PopupAction: NSView {

    private let button = NSButton()
    private let pressed: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.pressed = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = #selector(press)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func press() { pressed() }

    /// Brings Roost forward on a Settings page. The popup closes itself when
    /// the Settings window takes key, so nothing here has to find it.
    static func openSettings(_ pane: String) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NotificationCenter.default.post(name: .toggleSettings, object: nil,
                                        userInfo: ["module": pane])
    }
}
