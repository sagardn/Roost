import AppKit

/// The Sensors popup: every hardware sensor this Mac publishes, grouped by
/// what it measures.
///
/// Reads `SensorReadings` only -- the HID sensor service for temperatures
/// and AppleSMC for the electrical families. Both unprivileged, neither
/// prompting for anything.
final class SensorsModule: PopupContent {

    let title = "Sensors"
    var menuBarLabel: String { "SEN" }

    /// A sensor reading is a figure with a unit, not a proportion, so the
    /// shapes that draw a share of something are not offered: a ring filled
    /// to 40 would be claiming the die is 40% of the way to somewhere, and
    /// there is no somewhere. A figure, the name, and a chart of its own
    /// history are the three that mean anything.
    var menuBarStyles: [MenuBarStyle] { [.label, .mini, .lineChart] }
    var defaultMenuBarStyles: [MenuBarStyle] { [.mini] }

    func title(for style: MenuBarStyle) -> String {
        style == .lineChart ? localized("History") : style.title
    }

    private let headline = BigReading(caption: localized("Watched"), symbol: "thermometer.medium",
                                      tint: .roostAmber)
    private let hottest = BigReading(caption: localized("Hottest"), symbol: "flame", tint: .roostCritical)
    private let status = StatusLine()
    private let history = HistoryChart(height: 60)

    /// Built for more sensors than any Mac has, so a row is never made on a
    /// refresh; rows move between the family groups as the list changes.
    private let rows = (0..<48).map { _ in SensorRow() }

    /// A header and its rows, one per family. Groups rather than one flat
    /// stack because a flat stack cannot interleave: the headers were all
    /// added before the rows, so every visible header sat at the top in a
    /// block and the sensors under them belonged to none of them.
    private let groups: [NSStackView] = SensorReadings.Family.allCases.map { family in
        let group = NSStackView(views: [SectionHeader(family.rawValue)])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.isHidden = true
        return group
    }
    /// The sensor ids the groups were last arranged for. Rows are only moved
    /// when this changes, which is when a sensor is shown or hidden, not on
    /// every refresh.
    private var arranged: [String] = []

    private var sensors: [SensorReadings.Sensor] = []
    private var watchedHistory: [Double] = []
    private var tile: SensorsTile?
    private var ticks = 0
    /// Whether the popup is on screen, so the full table is worth reading.
    private var isShowing = false

    // MARK: - View

    func makeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(status)
        stack.setCustomSpacing(12, after: status)

        let pair = headlinePair(headline, hottest)
        stack.addArrangedSubview(pair)
        stack.setCustomSpacing(12, after: pair)

        stack.addArrangedSubview(history)
        stack.setCustomSpacing(14, after: history)

        for group in groups {
            stack.addArrangedSubview(group)
            stack.setCustomSpacing(14, after: group)
        }
        return stack
    }

    func makeTile() -> SensorsTile {
        if let tile { return tile }
        let made = SensorsTile()
        if !sensors.isEmpty { made.update(sensors, watched: watched) }
        tile = made
        return made
    }

    func willStop() {}

    func willShow() {
        isShowing = true
        // Fresh on open: between full reads only the watched sensor moved.
        sensors = SensorReadings.all(includingHID: SensorsSettings.includesHID)
    }

    func didHide() { isShowing = false }

    // MARK: - Sampling

    func menuBarContent() -> MenuBarReading? {
        // The menu bar shows one reading, so with nobody looking at the
        // list only that one is read again. Every sensor is read while the
        // popup or tile is open, and once every half minute regardless, so
        // "the hottest" can move to a different sensor. Reading all of them
        // on every interval was 88% of the app's time on the tick (measured
        // with `sample`: 338 of 386 samples), for one number.
        let due = ticks % SensorsSettings.interval == 0
        let looking = isShowing || tile?.window?.isVisible == true
        if sensors.isEmpty || (due && (looking || ticks % 30 == 0)) {
            sensors = SensorReadings.all(includingHID: SensorsSettings.includesHID)
        } else if due, let current = watched,
                  let index = sensors.firstIndex(where: { $0.id == current.id }) {
            if let fresh = SensorReadings.reread(current, includingHID: SensorsSettings.includesHID) {
                sensors[index] = fresh
            } else {
                sensors = SensorReadings.all(includingHID: SensorsSettings.includesHID)
            }
        }
        ticks += 1

        guard let watched else {
            return MenuBarReading(label: menuBarLabel, value: "—")
        }

        watchedHistory.append(watched.value)
        if watchedHistory.count > 120 {
            watchedHistory.removeFirst(watchedHistory.count - 120)
        }

        if let tile, tile.window?.isVisible == true { tile.update(sensors, watched: watched) }

        // A sensor reading is not a proportion, so there is no honest load
        // to colour by -- except for a temperature, where the ramp has a
        // meaning everybody shares. Everything else draws plain.
        let load: Double = watched.family == .temperature
            ? min(max((watched.value - 30) / 70, 0), 1) : 0

        // The chart needs its own scale: a die at 45 °C and one at 47 °C are
        // a flat line against an axis that starts at zero.
        let span = watchedHistory.range()
        return MenuBarReading(
            label: menuBarLabel,
            load: load,
            value: watched.formatted,
            severity: watched.family == .temperature ? .ofTemperature(watched.value) : .calm,
            history: watchedHistory.map { span.normalise($0) })
    }

    /// The sensor the menu bar figure is about.
    private var watched: SensorReadings.Sensor? {
        if let chosen = SensorsSettings.watched,
           let sensor = sensors.first(where: { $0.id == chosen }) {
            return sensor
        }
        // Nothing chosen, or the chosen one has gone: the hottest reading,
        // which is the one somebody watching sensors at all is watching for.
        return sensors.filter { $0.family == .temperature }.max { $0.value < $1.value }
    }

    // MARK: - Rendering

    func refresh() {
        guard !sensors.isEmpty else { return }

        if let watched {
            headline.set(text: watched.formatted.replacingOccurrences(of: "°", with: ""),
                         unit: watched.family == .temperature ? "°C" : watched.family.unit)
        }
        if let hot = sensors.filter({ $0.family == .temperature }).max(by: { $0.value < $1.value }) {
            hottest.set(text: String(format: "%.0f", hot.value), unit: "°C")
            let severity = MenuBarReading.Severity.ofTemperature(hot.value)
            let word: String
            switch severity {
            case .calm:     word = localized("Normal")
            case .warning:  word = localized("Running hot")
            case .critical: word = localized("Too hot")
            }
            status.set(word, tint: severity.tint,
                       // Not the hottest sensor's name: many are bare SMC
                       // keys -- "TCMz" -- which name nothing to a reader.
                       details: ["\(sensors.count) sensors"])
        }
        history.values = watchedHistory.range().normalised(watchedHistory)

        layout()
    }

    /// Puts the visible sensors under their family headers.
    private func layout() {
        let shown = sensors.filter { SensorsSettings.isShown($0.id) }
        let ordered = Array(SensorReadings.Family.allCases
            .flatMap { family in shown.filter { $0.family == family } }
            .prefix(rows.count))

        let ids = ordered.map(\.id)
        if ids != arranged {
            arranged = ids
            regroup(ordered)
        }
        // Rows are in `ordered` order across the groups, so the n-th row is
        // the n-th sensor whichever group it sits in.
        for (row, sensor) in zip(rows, ordered) { row.set(sensor) }
    }

    private func regroup(_ ordered: [SensorReadings.Sensor]) {
        for row in rows where row.superview != nil {
            (row.superview as? NSStackView)?.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        var next = 0
        for (index, family) in SensorReadings.Family.allCases.enumerated() {
            let count = ordered.filter { $0.family == family }.count
            groups[index].isHidden = count == 0
            for _ in 0..<count {
                groups[index].addArrangedSubview(rows[next])
                next += 1
            }
        }
    }
}

/// A sensor's name and its reading.
final class SensorRow: NSView {

    private let name = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        addSubview(name)
        addSubview(value)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 17),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor,
                                           constant: 8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ sensor: SensorReadings.Sensor) {
        name.stringValue = sensor.name
        value.stringValue = sensor.formatted
        // Coloured only when hot, by the menu bar's own temperature bands.
        // The load ramp it used before turned every reading teal, which made
        // forty rows of colour and no warning. The other families have no
        // scale that everybody agrees on, so they stay plain.
        let severity = sensor.family == .temperature
            ? MenuBarReading.Severity.ofTemperature(sensor.value) : .calm
        value.textColor = severity == .calm ? .labelColor : severity.tint
    }
}

// MARK: - Dashboard

/// In this file because the sensor list is private to it.
extension SensorsModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        guard !sensors.isEmpty || ticks > 0 else { return nil }
        guard let watched else {
            return DashboardReport(value: "—", caption: localized("Sensors"),
                                   unavailable: localized("No sensor on this Mac answered."))
        }
        let isTemperature = watched.family == .temperature
        let span = watchedHistory.range()
        return DashboardReport(
            value: watched.formatted,
            caption: watched.name,
            severity: isTemperature ? .ofTemperature(watched.value) : .calm,
            facts: [.init(label: localized("Sensors read"), value: "\(sensors.count)")],
            // No health signal: see `HealthSignal` for why a raw sensor is
            // not a verdict on whether the Mac is too hot.
            history: watchedHistory.map { span.normalise($0) })
    }
}
