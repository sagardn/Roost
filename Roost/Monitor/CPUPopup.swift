import AppKit

/// The CPU popup: temperature and load up top, history, every core, the
/// user/system split, the cluster breakdown, run-queue averages, uptime, and
/// what is actually using the processor.
///
/// Reads `CPUReadings`, `Temperature` and `ProcessCPU` -- host_processor_info,
/// a handful of sysctls, IOHIDEventSystemClient and `ps`. Nothing from Kit
/// but the shared colour ramp.
final class CPUModule: PopupContent {

    let title = "CPU"
    var menuBarLabel: String { "CPU" }

    private let temperatureReading = BigReading(caption: localized("Temperature"),
                                                symbol: "thermometer.medium",
                                                tint: .roostAmber)
    private let totalReading = BigReading(caption: localized("Total"), symbol: "cpu", tint: .systemIndigo)

    private let status = StatusLine()
    private let history = HistoryChart(height: 60)
    private let bars = CoreBars()
    private let clusterRow = ValueRow(localized("Power-saving · fast cores"))
        .explained(localized("Your Mac has power-saving cores for light work and fast cores for heavy work."))

    // The user/system split as a bar with a chip per row, the same colours
    // the menu bar's ring divides into. Idle is the track the bar leaves.
    private let splitBar = ShareBar(height: 8)
    private let userRow = ValueRow(localized("User"), symbol: "square.fill", tint: .roostBlue)
        .explained(localized("Time spent running apps."))
    private let systemRow = ValueRow(localized("System"), symbol: "square.fill", tint: .roostMagenta)
        .explained(localized("Time spent in macOS itself, much of it on work apps asked for."))

    // One row, not three under their own header: the three figures are only
    // ever read against each other, rising or falling.
    private let averageRow = ValueRow(localized("Load average · 1, 5, 15 min"))
        .explained(localized("How many tasks were waiting for the processor, on average. Below the number of cores means it is keeping up."))

    private let brandRow = ValueRow(localized("Processor"))
    private let coresRow = ValueRow(localized("Cores"))
    private let frequencyRow = ValueRow(localized("Clock"))
    private let uptimeRow = ValueRow(localized("Uptime"))
    private let detailsToggle = DisclosureButton(key: "CPU_popupDetails")

    /// Shown only on a Mac that is being held back. See `CPUReadings.Limits`:
    /// macOS reports these once it has had cause to, and an idle machine has
    /// nothing to report.
    private let limitsHeader = SectionHeader(localized("Held back to cool down"))
    private let schedulerRow = ValueRow(localized("Processor time allowed"))
        .explained(localized("macOS lets apps use only this share of the processor while it cools down."))
    private let availableCoresRow = ValueRow(localized("Cores available"))
    private let speedRow = ValueRow(localized("Top speed allowed"))
        .explained(localized("The highest speed the processor may run at right now, as a share of its full speed."))

    /// Built for the largest the setting allows, and the surplus hidden, so
    /// changing the count does not mean rebuilding the view.
    private let processPlaceholder = ProcessPlaceholder()
    private let processRows = (0..<12).map { _ in ProcessRow() }

    /// The tile the combined details popup stacks, once something has asked
    /// for it. Held here rather than rebuilt, because it is refreshed in
    /// place from the sample the menu bar reading already took.
    private var tile: CPUTile?

    /// The most recent sample, taken by `menuBarContent()`. The popup reads
    /// it rather than sampling again -- two callers differencing the same
    /// cumulative tick counters would each see half the load.
    private var latest: CPUReadings.Load?
    /// Kept here rather than in the chart so it survives the popup closing.
    private var usageHistory: [Double] = []
    private var historyLimit: Int { max(30, CPUSettings.historyLength) }

    private var ticks = 0

    /// The thresholds this module is watching, if any are switched on.
    private let thresholds = ThresholdWatcher<CPUThreshold>(
        title: localized("CPU is busy"))

    // MARK: - View

    func makeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(status)
        stack.setCustomSpacing(12, after: status)

        // Load first: it is what the popup is named for, and the temperature
        // can be switched off, which left the headline lopsided the other
        // way round.
        let headline = headlinePair(totalReading, temperatureReading)
        stack.addArrangedSubview(headline)
        stack.setCustomSpacing(12, after: headline)

        stack.addArrangedSubview(history)
        stack.setCustomSpacing(14, after: history)

        stack.addArrangedSubview(SectionHeader(localized("Cores")))
        stack.addArrangedSubview(bars)
        stack.addArrangedSubview(clusterRow)
        stack.setCustomSpacing(10, after: clusterRow)

        stack.addArrangedSubview(splitBar)
        stack.setCustomSpacing(4, after: splitBar)
        for row in [userRow, systemRow, averageRow] { stack.addArrangedSubview(row) }

        stack.addArrangedSubview(limitsHeader)
        for row in [schedulerRow, availableCoresRow, speedRow] {
            stack.addArrangedSubview(row)
        }
        setLimits(CPUReadings.Limits())

        stack.addArrangedSubview(SectionHeader(localized("Busiest apps · 100% = one core")))
        stack.addArrangedSubview(processPlaceholder)
        for row in processRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        detailsToggle.install(in: stack, rows: [brandRow, coresRow, frequencyRow, uptimeRow])
        detailsToggle.onToggle = { [weak self] open in
            // The clock row stays hidden where there is no clock to show.
            if open, CPUReadings.describeFrequency() == nil { self?.frequencyRow.isHidden = true }
        }

        brandRow.value = CPUReadings.brand ?? "—"
        if let clusters = CPUReadings.clusters {
            coresRow.value = "\(CPUReadings.coreCount) · \(clusters.efficiency)E + \(clusters.performance)P"
            bars.clusterBreak = clusters.efficiency
        } else {
            coresRow.value = "\(CPUReadings.coreCount) logical"
        }
        // Nothing to show where the sensors are not readable (Intel, or a
        // kernel that declines) -- better an em dash than a confident zero.
        temperatureReading.isHidden = !CPUSettings.showsTemperature

        // Absent on Apple silicon, and there is no public substitute -- see
        // `CPUReadings.nominalFrequency`. The row goes rather than showing a
        // dash where a number has never existed.
        if let clock = CPUReadings.describeFrequency() {
            frequencyRow.value = clock
        } else {
            frequencyRow.isHidden = true
        }
        if !Temperature.isAvailable { temperatureReading.set(text: "—", unit: "") }

        return stack
    }

    /// The tile, built once.
    func makeTile() -> CPUTile {
        if let tile { return tile }
        let made = CPUTile()
        if let latest { made.update(latest) }
        tile = made
        return made
    }

    // MARK: - Sampling

    func menuBarContent() -> MenuBarReading? {
        guard let load = CPUReadings.load() else { return nil }
        latest = load
        usageHistory.append(load.total)
        if usageHistory.count > historyLimit {
            usageHistory.removeFirst(usageHistory.count - historyLimit)
        }
        // Only while somebody is looking at it. This runs on every tick
        // whether a popup is open or not, which is the point of it -- a menu
        // bar reading that only moved while the popup was up would be
        // useless -- but drawing a tile into a closed window would not be.
        if let tile, tile.window?.isVisible == true { tile.update(load) }

        // Checked from the module's own sample rather than from a reading of
        // its own: a threshold should cost nothing until it fires.
        thresholds.check { kind in
            switch kind {
            case .total:       return load.total
            case .system:      return load.system
            case .user:        return load.user
            case .efficiency:  return CPUReadings.clusterLoad(load.cores)?.efficiency
            case .performance: return CPUReadings.clusterLoad(load.cores)?.performance
            }
        }

        // Everything the six menu bar shapes can draw, from this one sample:
        // the figure, the history the line chart needs, a bar per core, and
        // the user/system split the ring and the gauge divide themselves
        // into. Both colours are from the validated palette.
        return MenuBarReading(
            label: "CPU",
            load: load.total,
            value: "\(Int((load.total * 100).rounded()))%",
            // Raised while macOS is slowing the processor to cool it, so a
            // held-back Mac shows in the menu bar even at a low load.
            severity: Throttling.severity(load: .of(load: load.total), Throttling.current),
            history: usageHistory,
            bars: load.cores.map { $0.total },
            segments: [.init(load.system, .roostMagenta), .init(load.user, .roostBlue)])
    }

    func didHide() { ProcessCPU.top(0) { _ in } }

    /// At quit. An alert about a reading nothing is watching any more is one
    /// that can never be taken down.
    func willStop() { thresholds.withdrawAll() }

    func refresh() {
        ticks += 1

        if let temperature = Temperature.cpu() {
            temperatureReading.set(text: String(format: "%.0f", temperature), unit: "°C")
        }

        let uptime = CPUReadings.uptime().map { CPUReadings.describe(uptime: $0) }

        if let load = latest {
            totalReading.set(percent: load.total)
            history.values = usageHistory
            bars.loads = load.cores.map { $0.total }

            let thermal = Throttling.current
            let severity = Throttling.severity(load: .of(load: load.total), thermal)
            status.set(thermal.verdict ?? StatusWords.load(load.total),
                       tint: severity.tint,
                       details: [thermal >= .throttled ? localized("slowed down to cool off") : nil,
                                 thermal == .warm ? localized("warming up") : nil,
                                 CPUReadings.brand,
                                 uptime.map { "up " + $0 }].compactMap { $0 })

            splitBar.segments = [.init(fraction: load.user, color: .roostBlue),
                                 .init(fraction: load.system, color: .roostMagenta)]
            userRow.value = percent(load.user)
            systemRow.value = percent(load.system)

            if let clusters = CPUReadings.clusterLoad(load.cores) {
                clusterRow.value = "\(percent(clusters.efficiency)) · \(percent(clusters.performance))"
                clusterRow.isHidden = false
            } else {
                clusterRow.isHidden = true
            }
        }

        if let average = CPUReadings.loadAverage() {
            averageRow.value = String(format: "%.2f · %.2f · %.2f",
                                      average.one, average.five, average.fifteen)
        }

        if let uptime { uptimeRow.value = uptime }

        // Spawns ps, so every other tick rather than every one.
        if ticks % 2 == 1 { refreshProcesses() }

        // Spawns pmset, and these figures move when a Mac gets hot, which is
        // minutes. Every tenth tick, and only while the popup is open --
        // `refresh` is not called otherwise.
        if ticks % 10 == 1 {
            CPUReadings.limits { [weak self] in self?.setLimits($0) }
        }
    }

    private func setLimits(_ limits: CPUReadings.Limits) {
        for view in [limitsHeader, schedulerRow, availableCoresRow, speedRow] {
            view.isHidden = limits.isEmpty
        }
        guard !limits.isEmpty else { return }
        schedulerRow.isHidden = limits.scheduler == nil
        availableCoresRow.isHidden = limits.availableCores == nil
        speedRow.isHidden = limits.speed == nil
        if let value = limits.scheduler { schedulerRow.value = "\(value)%" }
        if let value = limits.availableCores { availableCoresRow.value = "\(value)" }
        if let value = limits.speed { speedRow.value = "\(value)%" }
    }

    private func refreshProcesses() {
        let wanted = min(CPUSettings.processCount, processRows.count)
        guard wanted > 0 else {
            processRows.forEach { $0.isHidden = true }
            processPlaceholder.isHidden = true
            return
        }
        ProcessCPU.top(wanted) { [weak self] entries in
            guard let self else { return }
            self.processPlaceholder.show(rows: entries.count, empty: localized("Nothing is busy"))
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

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

// MARK: - Dashboard

/// In this file because `latest` and `usageHistory` are private to it.
extension CPUModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        guard let load = latest else { return nil }
        let thermal = Throttling.current
        let severity = Throttling.severity(load: .of(load: load.total), thermal)

        var facts = [DashboardReport.Fact(label: localized("User"), value: percent(load.user)),
                     DashboardReport.Fact(label: localized("System"), value: percent(load.system))]
        // getloadavg is one syscall, not a sample: the kernel keeps it.
        if let average = CPUReadings.loadAverage() {
            facts.append(.init(label: localized("Load average"),
                               value: String(format: "%.2f", average.one)))
        }
        return DashboardReport(
            value: "\(Int((load.total * 100).rounded()))%",
            caption: thermal.verdict ?? StatusWords.load(load.total),
            severity: severity,
            facts: facts,
            history: usageHistory,
            signal: .cpu(recentLoad: Health.recentMean(usageHistory) ?? load.total,
                         throttled: thermal >= .throttled))
    }
}
