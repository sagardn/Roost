import AppKit

/// Storage's tile in the combined details popup.
///
/// How full the startup volume is, how that has moved, and what the disk is
/// doing right now. The rates share the row with the capacity rather than
/// getting a chart of their own: at tile height two mirrored series would be
/// four pixels each, and the question a tile answers about storage is
/// "is it filling up", not "what is it reading".
final class DiskTile: NSView {

    static let height: CGFloat = 86

    private let value = NSTextField(labelWithString: "—")
    private let chart = CapacityBar()
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("Disk").uppercased())
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
            chart.heightAnchor.constraint(equalToConstant: 14),

            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ volume: DiskReadings.Volume,
                activity: DiskReadings.Activity,
                history: [Double]) {
        let band = LoadBand.of(volume.percent)
        value.stringValue = "\(Int((volume.percent * 100).rounded()))%"
        value.textColor = band.color
        value.font = .systemFont(ofSize: 22, weight: band.weight)

        chart.share = volume.percent
        chart.tint = band.color

        // Free space first, because that is the number somebody checks a
        // disk for. The rates follow it only when there is something to say:
        // "0 B/s" on an idle disk is a line that says nothing.
        var parts = ["\(volume.name)   \(Readings.bytes(volume.free)) \(localized("free"))"]
        if activity.read > 0 || activity.written > 0 {
            parts.append("↓ \(Readings.rate(activity.read))")
            parts.append("↑ \(Readings.rate(activity.written))")
        } else {
            parts.append(Readings.bytes(volume.total))
        }
        detail.stringValue = parts.joined(separator: "   ")
    }
}

/// A single bar: how much of the volume is gone.
///
/// Not a history chart. A disk filling up is measured in days, so sixty
/// seconds of it is a flat line, and a flat line at 97% looks exactly like a
/// flat line at 12% unless you read the axis -- which at this height there is
/// no room to print.
private final class CapacityBar: NSView {

    var share: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = .roostCalm { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        track.fill()

        guard share.isFinite, share > 0 else { return }
        track.setClip()
        tint.setFill()
        NSRect(x: bounds.minX, y: bounds.minY,
               width: CGFloat(min(max(share, 0), 1)) * bounds.width,
               height: bounds.height).fill()
    }
}
