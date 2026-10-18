import AppKit

/// Memory's tile in the combined details popup.
///
/// What a glance at memory should answer: how much is taken, what is holding
/// it, and whether the machine has started swapping -- which is the part that
/// decides whether a high percentage matters at all. A Mac sitting at 85%
/// with no swap is fine; one at 65% swapping steadily is not, and a tile that
/// showed only the percentage would have those the wrong way round.
final class RAMTile: NSView {

    static let height: CGFloat = 86

    private let value = NSTextField(labelWithString: "—")
    private let bar = MemoryBar()
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("Memory").uppercased())
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 22, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        bar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption)
        addSubview(value)
        addSubview(bar)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: caption.firstBaselineAnchor,
                                                 constant: 6),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 4),
            bar.heightAnchor.constraint(equalToConstant: 14),

            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Drawn from the sample the menu bar reading already took.
    func update(_ usage: MemoryReadings.Usage, swap: MemoryReadings.Swap?,
                pressure: MemoryReadings.Pressure) {
        let band = LoadBand.of(usage.percent)
        value.stringValue = "\(Int((usage.percent * 100).rounded()))%"
        value.textColor = band.color
        value.font = .systemFont(ofSize: 22, weight: band.weight)

        let total = Double(max(usage.total, 1))
        bar.parts = [
            .init(Double(usage.app) / total, .roostBlue),
            .init(Double(usage.wired) / total, .roostMagenta),
            .init(Double(usage.compressed) / total, .roostOlive)
        ]

        var parts = [
            "\(localized("App")) \(Readings.bytes(usage.app))",
            "\(localized("Wired")) \(Readings.bytes(usage.wired))"
        ]
        // Swap is reported only once there is some: a line saying "Swap 0 B"
        // on a machine that has never swapped is a line that says nothing,
        // and the whole point of the row is that it appearing is the news.
        if let swap, swap.isInUse {
            parts.append("\(localized("Swap")) \(Readings.bytes(swap.used))")
        } else if pressure != .normal {
            parts.append("\(localized("Pressure")) \(localized(pressure.label))")
        } else {
            parts.append("\(localized("Free")) \(Readings.bytes(usage.free + usage.cached))")
        }
        detail.stringValue = parts.joined(separator: "   ")
    }
}

/// A single bar split into the parts memory is holding.
///
/// One bar rather than a row of them: memory has no cores to compare, it has
/// a budget, and the thing worth seeing is how much of it is gone and to
/// what. The remainder is drawn as a track so the bar is always full width
/// and the filled share is read against something.
private final class MemoryBar: NSView {

    struct Part {
        let share: Double
        let color: NSColor

        init(_ share: Double, _ color: NSColor) {
            self.share = share
            self.color = color
        }
    }

    var parts: [Part] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        (NSColor.tertiaryLabelColor).withAlphaComponent(0.25).setFill()
        track.fill()

        track.setClip()
        var x = bounds.minX
        for part in parts {
            guard part.share.isFinite, part.share > 0 else { continue }
            let width = CGFloat(min(max(part.share, 0), 1)) * bounds.width
            part.color.setFill()
            NSRect(x: x, y: bounds.minY, width: width, height: bounds.height).fill()
            x += width
            if x >= bounds.maxX { break }
        }
    }
}
