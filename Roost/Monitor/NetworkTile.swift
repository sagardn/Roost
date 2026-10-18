import AppKit

/// Network's tile in the combined details popup.
///
/// Two rates and the shape of the last couple of minutes. A single number
/// cannot say anything useful about a link -- "1.2 MB/s" is a lot on a hotel
/// connection and nothing on a wired one -- so the tile shows the pair
/// against their own recent history rather than against a ceiling nothing
/// reports.
final class NetworkTile: NSView {

    static let height: CGFloat = 86

    private let download = NSTextField(labelWithString: "—")
    private let upload = NSTextField(labelWithString: "—")
    private let chart = MiniTrafficChart()
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("Network").uppercased())
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        for (field, tint) in [(upload, NSColor.roostAmber), (download, .systemIndigo)] {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.textColor = tint
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        chart.translatesAutoresizingMaskIntoConstraints = false

        // Upload over download, as the menu bar and the chart beside it.
        let rates = NSStackView(views: [upload, download])
        rates.orientation = .vertical
        rates.alignment = .trailing
        rates.spacing = 0
        rates.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption)
        addSubview(rates)
        addSubview(chart)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            rates.trailingAnchor.constraint(equalTo: trailingAnchor),
            rates.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.topAnchor.constraint(equalTo: rates.bottomAnchor, constant: 2),
            chart.heightAnchor.constraint(equalToConstant: 26),

            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ monitor: NetworkMonitor, interface: String?) {
        download.stringValue = "↓ " + Readings.rate(monitor.rates.download)
        upload.stringValue = "↑ " + Readings.rate(monitor.rates.upload)
        chart.up = monitor.uploadHistory
        chart.down = monitor.downloadHistory

        var parts: [String] = []
        if let interface { parts.append(interface) }
        parts.append(monitor.link.isReachable ? localized("Online") : localized("Offline"))
        parts.append("↓ " + Readings.bytes(monitor.sessionDownload))
        parts.append("↑ " + Readings.bytes(monitor.sessionUpload))
        detail.stringValue = parts.joined(separator: "   ")
    }
}

/// Upload above the line, download below, on one shared scale.
///
/// The popup's `TrafficChart` prints peaks and axis labels and is sized for a
/// panel; this is the same idea at a quarter of the height, where a label
/// would be unreadable and the shape is the entire point.
private final class MiniTrafficChart: NSView {

    var up: [Double] = [] { didSet { needsDisplay = true } }
    var down: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke()
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 3, yRadius: 3)
        frame.lineWidth = 1
        frame.stroke()

        let inner = bounds.insetBy(dx: 2, dy: 2)
        let peak = max(up.max() ?? 0, down.max() ?? 0)
        guard peak > 0, inner.width > 0 else { return }
        let middle = inner.midY

        for (values, color, above) in [(up, NSColor.roostAmber, true),
                                       (down, NSColor.systemIndigo, false)] {
            guard values.count > 1 else { continue }
            let step = inner.width / CGFloat(values.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inner.minX, y: middle))
            for (index, value) in values.enumerated() {
                let share = value.isFinite ? CGFloat(min(max(value / peak, 0), 1)) : 0
                let height = share * (inner.height / 2)
                path.line(to: NSPoint(x: inner.minX + CGFloat(index) * step,
                                      y: above ? middle + height : middle - height))
            }
            path.line(to: NSPoint(x: inner.maxX, y: middle))
            path.close()
            color.withAlphaComponent(0.5).setFill()
            path.fill()
        }
    }
}
