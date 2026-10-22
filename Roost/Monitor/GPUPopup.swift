import AppKit

/// The GPU popup: how busy the graphics processor is, what it is busy with,
/// and what the machine has.
///
/// Reads `GPUStats` -- the `PerformanceStatistics` dictionary every
/// accelerator driver publishes in the IORegistry -- and `ProcessGPU`, the
/// per-app GPU time from the same registry's user clients. Public, no
/// entitlement, no private framework.
///
/// The process list is what the popup was missing: "Heavy load" with no
/// word on what was loading it sent everyone to Activity Monitor, which has
/// the same figure in a column most people never switch on.
final class GPUModule: PopupContent {

    let title = "GPU"
    var menuBarLabel: String { "GPU" }

    private let usageReading = BigReading(caption: localized("Utilization"), symbol: "cpu",
                                          tint: .systemIndigo)
    private let memoryReading = BigReading(caption: localized("Memory"), symbol: "memorychip",
                                           tint: .roostAmber)

    private let status = StatusLine()
    private let history = HistoryChart(height: 60)

    // One row: the two stages are only read against each other.
    private let splitRow = ValueRow(localized("Renderer · tiler"))

    // No "Memory in use" row: it repeated the headline figure exactly.
    private let modelRow = ValueRow(localized("Model"))
    private let coresRow = ValueRow(localized("Cores"))
    private let detailsToggle = DisclosureButton(key: "GPU_popupDetails")
    private let acceleratorsHeader = SectionHeader(localized("Accelerators"))

    /// One row per accelerator, for a Mac with more than one. Built for a
    /// handful and the surplus hidden, so a machine that gains an eGPU does
    /// not need the view rebuilt.
    private let deviceRows = (0..<4).map { _ in ValueRow("") }

    private let processPlaceholder = ProcessPlaceholder()
    private let processRows = (0..<8).map { _ in ProcessRow() }
    private var ticks = 0

    private var latest: GPUStats.Reading?
    private var devices: [GPUStats.Reading] = []
    private var usageHistory: [Double] = []
    private var historyLimit: Int { max(30, GPUSettings.historyLength) }

    private var tile: GPUTile?

    private let thresholds = ThresholdWatcher<GPUThreshold>(
        title: localized("Graphics are busy"))

    // MARK: - View

    func makeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(status)
        stack.setCustomSpacing(12, after: status)

        let headline = headlinePair(usageReading, memoryReading)
        stack.addArrangedSubview(headline)
        stack.setCustomSpacing(12, after: headline)

        stack.addArrangedSubview(history)
        stack.setCustomSpacing(10, after: history)
        stack.addArrangedSubview(splitRow)

        // Only on a Mac with more than one: with a single GPU the list was
        // the headline again, under a header of its own.
        acceleratorsHeader.isHidden = true
        stack.addArrangedSubview(acceleratorsHeader)
        for row in deviceRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        // Above the details, under the figures it explains: the busy
        // number, then who is making it busy.
        stack.setCustomSpacing(12, after: deviceRows.last ?? splitRow)
        stack.addArrangedSubview(SectionHeader(localized("Busiest apps · GPU time")))
        stack.addArrangedSubview(processPlaceholder)
        for row in processRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        detailsToggle.install(in: stack, rows: [modelRow, coresRow])

        coresRow.value = GPUStats.coreCount.map { "\($0)" } ?? "—"
        return stack
    }

    /// The tile, built once.
    func makeTile() -> GPUTile {
        if let tile { return tile }
        let made = GPUTile()
        if let latest { made.update(latest, history: usageHistory) }
        tile = made
        return made
    }

    func willStop() { thresholds.withdrawAll() }

    func didHide() { ProcessGPU.top(0) { _ in } }

    // MARK: - Sampling

    func menuBarContent() -> MenuBarReading? {
        devices = GPUStats.read()
        // The busiest, which on a Mac with an integrated and a discrete GPU
        // is the one worth a number in the menu bar.
        guard let busiest = devices.max(by: { ($0.utilization ?? -1) < ($1.utilization ?? -1) })
        else { return nil }
        latest = busiest

        // A driver that reports no utilization at all gets no figure rather
        // than a zero: idle and unreported look identical as a number, and
        // only one of them is true.
        guard let utilization = busiest.utilization else {
            return MenuBarReading(label: "GPU", value: "—")
        }

        let share = utilization / 100
        usageHistory.append(share)
        if usageHistory.count > historyLimit {
            usageHistory.removeFirst(usageHistory.count - historyLimit)
        }

        if let tile, tile.window?.isVisible == true {
            tile.update(busiest, history: usageHistory)
        }

        thresholds.check { _ in share }

        var segments: [MenuBarReading.Segment] = []
        if let renderer = busiest.renderer, let tiler = busiest.tiler {
            // The two halves of the figure above, not two more readings:
            // scaled so together they fill exactly as much of the ring as
            // the utilization does.
            let sum = max(renderer + tiler, 0.0001)
            segments = [.init(share * (renderer / sum), .roostBlue),
                        .init(share * (tiler / sum), .roostMagenta)]
        }

        return MenuBarReading(
            label: "GPU",
            load: share,
            value: "\(Int(utilization.rounded()))%",
            history: usageHistory,
            segments: segments)
    }

    func refresh() {
        // Every other second, as the CPU list does: a rate needs two
        // samples, and a list that resorts every second cannot be read.
        ticks += 1
        if ticks % 2 == 1 { refreshProcesses() }

        guard let reading = latest else { return }

        if let utilization = reading.utilization {
            usageReading.set(percent: utilization / 100)
        } else {
            usageReading.set(text: "—", unit: "")
        }

        if let memory = reading.memoryUsed {
            memoryReading.set(bytes: memory)
        } else {
            memoryReading.set(text: "—", unit: "")
        }

        let load = (reading.utilization ?? 0) / 100
        status.set(reading.utilization == nil ? localized("No reading") : StatusWords.load(load),
                   tint: reading.utilization == nil ? .tertiaryLabelColor
                       : MenuBarReading.Severity.of(load: load).tint,
                   details: [reading.name] + [GPUStats.coreCount.map { "\($0) cores" }]
                       .compactMap { $0 })

        history.values = usageHistory
        let stage = { (value: Double?) in value.map { String(format: "%.0f%%", $0) } ?? "—" }
        splitRow.value = "\(stage(reading.renderer)) · \(stage(reading.tiler))"
        modelRow.value = reading.name

        acceleratorsHeader.isHidden = devices.count < 2
        for (index, row) in deviceRows.enumerated() {
            guard devices.count > 1, index < devices.count else {
                row.isHidden = true
                continue
            }
            let device = devices[index]
            row.label = device.name
            row.value = device.utilization.map { String(format: "%.0f%%", $0) } ?? "—"
            row.isHidden = false
        }
    }
}

// MARK: - Processes

extension GPUModule {
    private func refreshProcesses() {
        let wanted = min(GPUSettings.processCount, processRows.count)
        guard wanted > 0 else {
            processRows.forEach { $0.isHidden = true }
            processPlaceholder.isHidden = true
            return
        }
        ProcessGPU.top(wanted) { [weak self] sample in
            guard let self else { return }
            let entries: [ProcessGPU.Entry]
            switch sample {
            case .measuring:
                self.processPlaceholder.show(rows: 0, empty: localized("Measuring…"))
                self.processRows.forEach { $0.isHidden = true }
                return
            case .unreported:
                // Said in words: an empty list would claim nothing is using
                // a GPU the headline says is busy.
                self.processPlaceholder.show(rows: 0,
                    empty: localized("This GPU does not report which apps use it"))
                self.processRows.forEach { $0.isHidden = true }
                return
            case .busiest(let found):
                entries = found
            }
            self.processPlaceholder.show(rows: entries.count, empty: localized("Nothing is using the GPU"))
            for (index, row) in self.processRows.enumerated() {
                if index < entries.count {
                    let entry = entries[index]
                    row.set(name: entry.name, pid: entry.pid,
                            value: String(format: "%.1f%%", entry.usage))
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
        }
    }
}

// MARK: - Dashboard

/// In this file because the latest reading is private to it.
extension GPUModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        guard let reading = latest else { return nil }
        guard let utilization = reading.utilization else {
            // Idle and unreported look the same as a number; only one is
            // true, so the card says which.
            return DashboardReport(value: "—", caption: reading.name,
                                   unavailable: localized("This GPU's driver does not report how busy it is."))
        }
        var facts: [DashboardReport.Fact] = [.init(label: localized("Device"), value: reading.name)]
        if let memory = reading.memoryUsed {
            facts.append(.init(label: localized("Memory in use"), value: Readings.bytes(memory)))
        }
        let share = utilization / 100
        return DashboardReport(
            value: "\(Int(utilization.rounded()))%",
            caption: StatusWords.load(share),
            severity: .of(load: share),
            facts: facts,
            history: usageHistory)
    }
}
