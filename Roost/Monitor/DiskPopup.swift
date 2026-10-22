import AppKit

/// The storage popup: how full the disk is, what the volumes hold, and what
/// the devices are actually doing.
///
/// Two readings that have nothing to do with each other and belong on one
/// page: capacity, which moves in hours, and activity, which moves in
/// milliseconds. They are kept visually apart for that reason.
///
/// Reads `DiskReadings` only -- volume resource values and the IORegistry.
final class DiskModule: PopupContent {

    let title = "Disk"

    /// "SSD", not "Disk": it is what the module being replaced put in the
    /// menu bar, so it is what anyone running Roost already reads there.
    var menuBarLabel: String { "SSD" }

    /// Storage is the one module that fills every shape. It holds a capacity
    /// worth a figure, a ring and a pair; and it carries traffic worth a rate
    /// and a mirrored chart.
    var menuBarStyles: [MenuBarStyle] { MenuBarStyle.allCases.filter { $0 != .symbol } }

    private let usedReading = BigReading(caption: localized("Used"), symbol: "internaldrive",
                                         tint: .systemIndigo)
    private let freeReading = BigReading(caption: localized("Free"), symbol: "square.dashed",
                                         tint: .roostAmber)

    private let status = StatusLine()

    // A bar, not the history chart that was here: capacity moves in hours,
    // so its chart was a flat line ninety points tall saying "86%".
    private let capacityRow = ValueRow("")
    private let capacityBar = ShareBar(height: 10)
    /// Shown from "Filling up" on, under the bar that says so.
    private let freeUpSpace = PopupAction(localized("Free up space…"), symbol: "sparkles") {
        PopupAction.openSettings("Free up space")
    }

    private let traffic = SplitTrafficChart()
    private let peaks = PeakLegend(upperName: localized("write"), lowerName: localized("read"))
    private let nowRow = ValueRow(localized("Now"))
    private let sessionRow = ValueRow(localized("Since launch"))

    /// One per volume and one per device. Built for a handful and the
    /// surplus hidden, so plugging a drive in does not rebuild the view.
    private let othersHeader = SectionHeader(localized("Other volumes"))
    private let volumeRows = (0..<6).map { _ in VolumeRow() }
    private let deviceRows = (0..<6).map { _ in ValueRow("") }

    /// Only shown when there is some -- a row reading "0 B" would be noise on
    /// every Mac that has nothing held back.
    private let purgeableRow = ValueRow(localized("Purgeable"))
    private let formatRow = ValueRow(localized("Format"))
    private let totalRow = ValueRow(localized("Capacity"))
    private let mountRow = ValueRow(localized("Mounted at"))
    private let detailsToggle = DisclosureButton(key: "Disk_popupDetails")

    // MARK: - State

    private var latest: DiskReadings.Volume?
    private var volumes: [DiskReadings.Volume] = []
    private var activity = DiskReadings.Activity()
    private var deviceNames: [String] = []

    private let meter = DiskReadings.Meter()
    private var sessionRead: UInt64 = 0
    private var sessionWritten: UInt64 = 0

    private var usageHistory: [Double] = []
    private var readHistory: [Double] = []
    private var writeHistory: [Double] = []
    private var historyLimit: Int { max(30, DiskSettings.historyLength) }

    private var ticks = 0
    private var tile: DiskTile?

    private let thresholds = ThresholdWatcher<DiskThreshold>(
        title: localized("Disk is filling up"))

    // MARK: - View

    func makeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(status)
        stack.setCustomSpacing(12, after: status)

        let headline = headlinePair(usedReading, freeReading)
        stack.addArrangedSubview(headline)
        stack.setCustomSpacing(12, after: headline)

        stack.addArrangedSubview(capacityRow)
        stack.setCustomSpacing(4, after: capacityRow)
        stack.addArrangedSubview(capacityBar)
        stack.setCustomSpacing(6, after: capacityBar)
        freeUpSpace.isHidden = true
        stack.addArrangedSubview(freeUpSpace)
        stack.setCustomSpacing(14, after: freeUpSpace)

        stack.addArrangedSubview(SectionHeader(localized("Activity")))
        stack.addArrangedSubview(traffic)
        stack.setCustomSpacing(4, after: traffic)
        stack.addArrangedSubview(peaks)
        stack.setCustomSpacing(10, after: peaks)
        for row in [nowRow, sessionRow] { stack.addArrangedSubview(row) }

        // Only the volumes the bar above is not already about. The watched
        // one listed again here was the same figure twice.
        othersHeader.isHidden = true
        stack.addArrangedSubview(othersHeader)
        for row in volumeRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        // The per-device counters run from when the device attached, which
        // on an internal disk is boot -- weeks of totals, interesting once.
        detailsToggle.install(in: stack,
                              rows: [purgeableRow, formatRow, totalRow, mountRow] + deviceRows)
        detailsToggle.onToggle = { [weak self] _ in self?.refresh() }

        return stack
    }

    /// The tile, built once.
    func makeTile() -> DiskTile {
        if let tile { return tile }
        let made = DiskTile()
        if let latest { made.update(latest, activity: activity, history: usageHistory) }
        tile = made
        return made
    }

    func willStop() { thresholds.withdrawAll() }

    // MARK: - Sampling

    func menuBarContent() -> MenuBarReading? {
        sampleActivity()

        // Capacity moves in hours, not seconds, and asking costs a stat() of
        // every mounted volume. Every fifteenth tick, and once immediately.
        if ticks % 15 == 0 || latest == nil {
            volumes = DiskReadings.volumes(includingRemovable: DiskSettings.showsRemovable)
            latest = DiskReadings.choose(from: volumes,
                                         preferring: DiskSettings.watchedVolume)
        }
        ticks += 1

        guard let volume = latest else {
            // No volume answered at all. Nothing is better than a zero.
            return MenuBarReading(label: menuBarLabel, value: "—")
        }

        usageHistory.append(volume.percent)
        trim(&usageHistory)

        thresholds.check { _ in volume.percent }

        if let tile, tile.window?.isVisible == true {
            tile.update(volume, activity: activity, history: usageHistory)
        }

        let total = Double(max(volume.total, 1))
        return MenuBarReading(
            label: menuBarLabel,
            load: volume.percent,
            value: "\(Int((volume.percent * 100).rounded()))%",
            severity: .ofDisk(volume.percent),
            history: usageHistory,
            segments: [.init(Double(volume.used) / total, LoadBand.of(volume.percent).color)],
            pair: .init(Readings.size(volume.used), Readings.size(volume.free)),
            // Written on top: the shape puts ↑ on the top figure, and ↑ is
            // write in this popup, the tile and the chart below. Read on top
            // labelled reads as writes.
            rates: .init(Readings.rate(activity.written), Readings.rate(activity.read)),
            mirrored: .init(up: writeHistory, down: readHistory))
    }

    /// Differences the device counters into a rate.
    ///
    /// `Meter` does it per device, so a drive being unplugged does not throw
    /// away the sample for every other drive. A sample it refuses leaves the
    /// previous rate showing rather than reporting zero: a machine waking
    /// from sleep did not stop reading its disk, we just cannot say what it
    /// did while we were not counting.
    private func sampleActivity() {
        deviceNames = DiskReadings.counters().byDevice.keys.sorted()

        guard let sample = meter.sample() else { return }

        activity = sample.activity
        sessionRead += sample.read
        sessionWritten += sample.written

        readHistory.append(sample.activity.read)
        writeHistory.append(sample.activity.written)
        trim(&readHistory)
        trim(&writeHistory)
    }

    private func trim(_ buffer: inout [Double]) {
        if buffer.count > historyLimit { buffer.removeFirst(buffer.count - historyLimit) }
    }

    // MARK: - Rendering

    func refresh() {
        guard let volume = latest else { return }

        let severity = MenuBarReading.Severity.ofDisk(volume.percent)
        status.set(StatusWords.disk(volume.percent), tint: severity.tint,
                   details: [volume.name] + [volume.format].compactMap { $0 })

        // The startup volume only, as `DiskCleanup` reasons: an external
        // drive that full is usually an archive doing its job, and the
        // cleaner only looks in the home folder anyway.
        freeUpSpace.isHidden = !(volume.path == "/" && volume.percent >= StatusWords.fillingUpFrom)

        usedReading.set(percent: volume.percent)
        freeReading.set(bytes: volume.free)

        capacityRow.label = volume.name
        capacityRow.value = "\(Readings.size(volume.used)) of \(Readings.size(volume.total))"
        capacityBar.segments = [.init(fraction: volume.percent, color: severity.tint)]

        traffic.upper = writeHistory
        traffic.lower = readHistory
        peaks.set(upper: writeHistory.max() ?? 0, lower: readHistory.max() ?? 0)

        // Write first, as the chart and the menu bar both put it: ↑ is write
        // everywhere this module draws.
        nowRow.value = "↑ \(Readings.rate(activity.written))   ↓ \(Readings.rate(activity.read))"
        sessionRow.value = "↑ \(Readings.size(sessionWritten))   ↓ \(Readings.size(sessionRead))"

        // Space macOS will hand back when something needs it. Hidden at zero,
        // because the row exists to explain a gap and there is no gap to
        // explain then.
        purgeableRow.isHidden = !detailsToggle.isOpen || volume.purgeable == 0
        purgeableRow.value = Readings.size(volume.purgeable)

        formatRow.value = volume.format ?? "—"
        totalRow.value = Readings.size(volume.total)
        mountRow.value = volume.path == "/" ? localized("/ (the startup disk)") : volume.path

        let others = volumes.filter { $0.path != volume.path }
        othersHeader.isHidden = others.isEmpty
        for (index, row) in volumeRows.enumerated() {
            guard index < others.count else {
                row.isHidden = true
                continue
            }
            row.set(others[index])
            row.isHidden = false
        }

        let counters = DiskReadings.counters().byDevice
        for (index, row) in deviceRows.enumerated() {
            guard detailsToggle.isOpen, index < deviceNames.count,
                  let entry = counters[deviceNames[index]] else {
                row.isHidden = true
                continue
            }
            // Written and read since the drive appeared, which for the
            // built-in one is since startup. The BSD name stays, as the
            // only name the counters have; the words say what it counts.
            row.label = localized("%0, written · read", deviceNames[index])
            row.toolTip = localized("Since the drive was connected; for a built-in drive, since startup.")
            row.value = "↑ \(Readings.size(entry.written))   ↓ \(Readings.size(entry.read))"
            row.isHidden = false
        }
    }
}

/// A volume's name and how full it is, over a thin bar of the same.
private final class VolumeRow: NSView {

    private let row = ValueRow("")
    private let bar = ShareBar(height: 4)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(bar)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            widthAnchor.constraint(equalTo: row.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ volume: DiskReadings.Volume) {
        row.label = volume.name
        row.value = "\(Readings.size(volume.used)) of \(Readings.size(volume.total))"
        bar.segments = [.init(fraction: volume.percent,
                              color: MenuBarReading.Severity.ofDisk(volume.percent).tint)]
    }
}

// MARK: - Dashboard

/// In this file because the watched volume is private to it.
extension DiskModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        guard let volume = latest else { return nil }
        return DashboardReport(
            value: "\(Int((volume.percent * 100).rounded()))%",
            caption: StatusWords.disk(volume.percent),
            severity: .ofDisk(volume.percent),
            // Available is what Finder calls free: space for important use,
            // after purgeable space -- the same figure the popup shows.
            facts: [.init(label: localized("Available"), value: Readings.size(volume.free)),
                    .init(label: localized("Used"), value: Readings.size(volume.used)),
                    .init(label: localized("Capacity"),
                          value: "\(Readings.size(volume.total)) · \(volume.name)"),
                    // What the disk is doing right now, which the capacity
                    // figures cannot say. Already differenced on this tick
                    // for the menu bar's traffic chart, so it costs nothing
                    // to repeat here -- and ↑ is write in this module
                    // everywhere else, so it is write here too.
                    .init(label: localized("Read and write"),
                          value: "↑ \(Readings.rate(activity.written))   ↓ \(Readings.rate(activity.read))")],
            // No line: a disk's fill moves over days, and two minutes of it
            // is a flat line. The capacity bar says what the line could not.
            fill: volume.percent,
            signal: .disk(used: volume.percent, free: volume.free, volume: volume.name),
            storage: storageDetail(volume))
    }

    /// The panel's figures, from this tick's sample. The two rate lines go
    /// on the larger of their peaks, so a quiet write reads as quiet beside
    /// a busy read -- the rule the Network card follows.
    private func storageDetail(_ volume: DiskReadings.Volume) -> StorageDetail {
        let peak = max(readHistory.max() ?? 0, writeHistory.max() ?? 0)
        let sampled = !readHistory.isEmpty
        return StorageDetail(volume: volume.name, total: volume.total, free: volume.free,
                             readRate: sampled ? activity.read : nil,
                             writeRate: sampled ? activity.written : nil,
                             readHistory: readHistory.normalised(against: peak),
                             writeHistory: writeHistory.normalised(against: peak))
    }
}
