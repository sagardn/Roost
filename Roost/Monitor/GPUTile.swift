import AppKit

/// GPU's tile in the combined details popup.
///
/// How busy the graphics processor is, the shape of the last couple of
/// minutes, and what it is. The split between renderer and tiler is in the
/// popup rather than here: at tile size it is two numbers that move together,
/// and the one worth a glance is the total.
final class GPUTile: NSView {

    static let height: CGFloat = 86

    private let value = NSTextField(labelWithString: "—")
    private let chart = SparkLine()
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("GPU").uppercased())
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 22, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        chart.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption)
        addSubview(value)
        addSubview(chart)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: caption.firstBaselineAnchor,
                                                 constant: 6),

            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 4),
            chart.heightAnchor.constraint(equalToConstant: 26),

            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ reading: GPUStats.Reading, history: [Double]) {
        if let utilization = reading.utilization {
            let share = utilization / 100
            let band = LoadBand.of(share)
            value.stringValue = "\(Int(utilization.rounded()))%"
            value.textColor = band.color
            value.font = .systemFont(ofSize: 22, weight: band.weight)
            chart.tint = band.color
        } else {
            // A driver reporting nothing is not a driver reporting zero.
            value.stringValue = "—"
            value.textColor = .tertiaryLabelColor
        }
        chart.values = history

        var parts = [reading.name]
        if let cores = GPUStats.coreCount { parts.append("\(cores) \(localized("cores"))") }
        if let memory = reading.memoryUsed { parts.append(Readings.bytes(memory)) }
        detail.stringValue = parts.joined(separator: "   ")
    }
}

/// A filled line, in a box, at tile height.
///
/// The popup's `HistoryChart` is seventy points tall and prints its own
/// scale; this is the same series in a quarter of that, where a label would
/// be unreadable and the shape is the whole message.
private final class SparkLine: NSView {

    var values: [Double] = [] { didSet { needsDisplay = true } }
    var tint: NSColor = .roostCalm { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke()
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 3, yRadius: 3)
        frame.lineWidth = 1
        frame.stroke()

        let inner = bounds.insetBy(dx: 2, dy: 2)
        guard values.count > 1, inner.width > 0 else { return }

        let step = inner.width / CGFloat(values.count - 1)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inner.minX, y: inner.minY))
        for (index, raw) in values.enumerated() {
            let share = raw.isFinite ? CGFloat(min(max(raw, 0), 1)) : 0
            path.line(to: NSPoint(x: inner.minX + CGFloat(index) * step,
                                  y: inner.minY + share * inner.height))
        }
        path.line(to: NSPoint(x: inner.maxX, y: inner.minY))
        path.close()

        tint.withAlphaComponent(0.45).setFill()
        path.fill()
        tint.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
