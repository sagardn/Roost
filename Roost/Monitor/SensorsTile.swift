import AppKit

/// Sensors' tile in the combined details popup.
///
/// The watched sensor's reading, the hottest thing in the machine, and how
/// many sensors answered. No chart: a sensor list is a list, and the one
/// number worth a glance is whether anything is hot.
final class SensorsTile: NSView {

    static let height: CGFloat = 86

    private let value = NSTextField(labelWithString: "—")
    private let summary = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: localized("Sensors").uppercased())
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 22, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption)
        addSubview(value)
        addSubview(summary)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: caption.firstBaselineAnchor,
                                                 constant: 6),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ sensors: [SensorReadings.Sensor], watched: SensorReadings.Sensor?) {
        guard let watched else {
            value.stringValue = "—"
            value.textColor = .tertiaryLabelColor
            summary.stringValue = localized("No sensors answered")
            detail.stringValue = ""
            return
        }

        value.stringValue = watched.formatted
        if watched.family == .temperature {
            let band = LoadBand.of(min(max((watched.value - 30) / 70, 0), 1))
            value.textColor = band.color
            value.font = .systemFont(ofSize: 22, weight: band.weight)
        } else {
            value.textColor = .labelColor
            value.font = .systemFont(ofSize: 22, weight: .regular)
        }
        summary.stringValue = watched.name

        // What else is worth a glance: the hottest reading, and the power
        // the machine is drawing if it says.
        var parts: [String] = []
        if let hot = sensors.filter({ $0.family == .temperature })
            .max(by: { $0.value < $1.value }), hot.id != watched.id {
            parts.append("\(localized("hottest")) \(hot.formatted)")
        }
        if let power = sensors.first(where: { $0.id == "PSTR" }) {
            parts.append(power.formatted)
        }
        parts.append("\(sensors.count) \(localized("sensors"))")
        detail.stringValue = parts.joined(separator: "   ")
    }
}
