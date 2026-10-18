import AppKit

/// CPU's tile in the combined details popup.
///
/// A tile is not a small popup. It is the one glance you would keep if you
/// could keep only one: how busy the processor is, how that load is spread
/// across the cores, and what it is spent on. Everything else is a click
/// away in the popup itself.
final class CPUTile: NSView {

    static let height: CGFloat = 86

    private let value = NSTextField(labelWithString: "—")
    private let bars = CoreBars(height: 26)
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("CPU").uppercased())
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 22, weight: .regular)
        value.textColor = .labelColor
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        bars.translatesAutoresizingMaskIntoConstraints = false
        if let clusters = CPUReadings.clusters { bars.clusterBreak = clusters.efficiency }

        addSubview(caption)
        addSubview(value)
        addSubview(bars)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: caption.firstBaselineAnchor,
                                                 constant: 6),

            bars.leadingAnchor.constraint(equalTo: leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: trailingAnchor),
            bars.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 4),

            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Drawn from the sample the menu bar reading already took. Nothing here
    /// reads the kernel: two callers differencing the same cumulative tick
    /// counters would each see half the load.
    func update(_ load: CPUReadings.Load) {
        let band = LoadBand.of(load.total)
        value.stringValue = "\(Int((load.total * 100).rounded()))%"
        value.textColor = band.color
        value.font = .systemFont(ofSize: 22, weight: band.weight)
        bars.loads = load.cores.map { $0.total }

        var parts = [
            "\(localized("User")) \(percent(load.user))",
            "\(localized("System")) \(percent(load.system))"
        ]
        if let clusters = CPUReadings.clusterLoad(load.cores) {
            parts.append("E \(percent(clusters.efficiency))")
            parts.append("P \(percent(clusters.performance))")
        }
        detail.stringValue = parts.joined(separator: "   ")
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
