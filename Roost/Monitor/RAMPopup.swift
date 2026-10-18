import AppKit

/// The memory popup: how much is in use, where it went, and -- the part that
/// actually matters -- whether the machine has started swapping.
///
/// Reads `MemoryReadings` only: `host_statistics64` and two sysctls.
final class RAMModule: PopupContent {

    /// "RAM", not "Memory": the title is the settings key prefix as well as
    /// the popup's heading, and every preference this module has ever had --
    /// `RAM_state`, `RAM_widget`, `RAM_notifications_*` -- is stored under
    /// that name. A nicer heading is not worth a second vocabulary.
    let title = "RAM"
    var menuBarLabel: String { "RAM" }

    private let usedReading = BigReading(caption: localized("Used"), symbol: "memorychip",
                                         tint: .systemIndigo)
    // "Available", not "Free": the figure is free plus cached files, which
    // the kernel hands back on demand. Labelled "Free" it sat above a
    // breakdown row also called "Free" showing a tenth of it.
    private let freeReading = BigReading(caption: localized("Available"), symbol: "square.dashed",
                                         tint: .roostAmber)

    private let status = StatusLine()

    // The breakdown as one bar with a chip per row, in the colours the menu
    // bar's segments already use for the same three shares.
    private let breakdownBar = ShareBar(height: 10)
    private let appRow = ValueRow(localized("App memory"), symbol: "square.fill", tint: .roostBlue)
    private let wiredRow = ValueRow(localized("Wired"), symbol: "square.fill", tint: .roostMagenta)
    private let compressedRow = ValueRow(localized("Compressed"), symbol: "square.fill", tint: .roostOlive)
    private let cachedRow = ValueRow(localized("Cached files"), symbol: "square.fill", tint: RAMModule.cachedTint)
    private let freeRow = ValueRow(localized("Free"), symbol: "square", tint: .tertiaryLabelColor)
    private static let cachedTint = NSColor.secondaryLabelColor.withAlphaComponent(0.45)

    private let swapUsedRow = ValueRow(localized("Swap used"))
    private let totalRow = ValueRow(localized("Physical"))
    private let swapTotalRow = ValueRow(localized("Swap size"))
    private let detailsToggle = DisclosureButton(key: "RAM_popupDetails")

    private let history = HistoryChart(height: 60)

    /// Built for the largest the setting allows and the surplus hidden, so
    /// changing the count does not mean rebuilding the view.
    private let processRows = (0..<12).map { _ in ProcessRow() }

    /// The tile, once something has asked for it.
    private var tile: RAMTile?

    /// The most recent sample, taken by `menuBarContent()`. The popup reads
    /// it rather than sampling again: two callers asking the kernel for its
    /// page counts a moment apart would disagree about the same instant.
    private var latest: MemoryReadings.Usage?
    private var latestSwap: MemoryReadings.Swap?
    private var latestPressure: MemoryReadings.Pressure = .normal

    /// Kept here rather than in the chart so it survives the popup closing.
    private var usageHistory: [Double] = []
    private var historyLimit: Int { max(30, RAMSettings.historyLength) }

    private var ticks = 0

    private let thresholds = ThresholdWatcher<RAMThreshold>(
        title: localized("Memory threshold"))

    /// The six, plus the pair of figures -- used over free -- that the
    /// module this replaces called `memory`. Not the two network shapes:
    /// memory has no direction and no second series.
    var menuBarStyles: [MenuBarStyle] {
        MenuBarStyle.allCases.filter { ![.rates, .trafficChart, .symbol].contains($0) }
    }

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

        stack.addArrangedSubview(history)
        stack.setCustomSpacing(14, after: history)

        stack.addArrangedSubview(SectionHeader(localized("Breakdown")))
        stack.addArrangedSubview(breakdownBar)
        stack.setCustomSpacing(6, after: breakdownBar)
        for row in [appRow, wiredRow, compressedRow, cachedRow, freeRow, swapUsedRow] {
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(SectionHeader(localized("Top processes · resident")))
        for row in processRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        detailsToggle.install(in: stack, rows: [totalRow, swapTotalRow])

        return stack
    }

    /// The tile, built once.
    func makeTile() -> RAMTile {
        if let tile { return tile }
        let made = RAMTile()
        if let latest { made.update(latest, swap: latestSwap, pressure: latestPressure) }
        tile = made
        return made
    }

    func didHide() { ProcessMemory.top(0) { _ in } }

    func willStop() { thresholds.withdrawAll() }

    // MARK: - Sampling

    func menuBarContent() -> MenuBarReading? {
        guard let usage = MemoryReadings.usage() else { return nil }
        latest = usage
        latestSwap = MemoryReadings.swap()
        latestPressure = MemoryReadings.pressure()

        usageHistory.append(usage.percent)
        if usageHistory.count > historyLimit {
            usageHistory.removeFirst(usageHistory.count - historyLimit)
        }

        if let tile, tile.window?.isVisible == true {
            tile.update(usage, swap: latestSwap, pressure: latestPressure)
        }

        thresholds.check { kind in
            switch kind {
            case .total:    return usage.percent
            case .free:     return usage.total == 0 ? nil
                                 : Double(usage.free + usage.cached) / Double(usage.total)
            case .pressure: return Double(self.latestPressure.rawValue)
            case .swap:     return self.latestSwap.map { Double($0.used) }
            }
        }

        let total = Double(max(usage.total, 1))
        return MenuBarReading(
            label: "RAM",
            load: usage.percent,
            value: "\(Int((usage.percent * 100).rounded()))%",
            // Flagged by the kernel's pressure, not the percentage: macOS
            // fills spare memory with cache on purpose, so 80% "used" is a
            // healthy machine, and the ramp turned it red.
            severity: latestPressure == .critical ? .critical
                : latestPressure == .warning ? .warning : .calm,
            history: usageHistory,
            // No bars of its own: memory has no cores to compare, so the bar
            // shape draws the single bar its fallback gives it.
            bars: [],
            segments: [.init(Double(usage.app) / total, .roostBlue),
                       .init(Double(usage.wired) / total, .roostMagenta),
                       .init(Double(usage.compressed) / total, .roostOlive)],
            pair: .init(Readings.bytes(usage.used),
                        Readings.bytes(usage.free + usage.cached)))
    }

    func refresh() {
        ticks += 1

        if let usage = latest {
            usedReading.set(percent: usage.percent)
            freeReading.set(bytes: usage.free + usage.cached)
            history.values = usageHistory

            let total = Double(max(usage.total, 1))
            breakdownBar.segments = [
                .init(fraction: Double(usage.app) / total, color: .roostBlue),
                .init(fraction: Double(usage.wired) / total, color: .roostMagenta),
                .init(fraction: Double(usage.compressed) / total, color: .roostOlive),
                .init(fraction: Double(usage.cached) / total, color: Self.cachedTint)
            ]
            appRow.value = Readings.bytes(usage.app)
            wiredRow.value = Readings.bytes(usage.wired)
            compressedRow.value = Readings.bytes(usage.compressed)
            cachedRow.value = Readings.bytes(usage.cached)
            freeRow.value = Readings.bytes(usage.free)
            totalRow.value = Readings.bytes(usage.total)
        }

        // Led by the kernel's pressure, not the percentage: macOS fills spare
        // memory with cache on purpose, so 80% "used" is a healthy machine.
        // Swap rides along because it is the other half of the same answer.
        let tint: NSColor = latestPressure == .critical ? .roostCritical
            : latestPressure == .warning ? .roostWarning : .roostCalm
        var details: [String] = []
        if let swap = latestSwap {
            details.append(swap.isInUse
                ? "\(Readings.bytes(swap.used)) swapped" : "no swap in use")
        }
        status.set("Pressure \(latestPressure.label.lowercased())", tint: tint, details: details)

        if let swap = latestSwap {
            swapUsedRow.value = Readings.bytes(swap.used)
            swapTotalRow.value = swap.total == 0 ? "none" : Readings.bytes(swap.total)
        } else {
            swapUsedRow.value = "—"
            swapTotalRow.value = "—"
        }

        // Spawns ps, so every other tick rather than every one.
        if ticks % 2 == 1 { refreshProcesses() }
    }

    private func refreshProcesses() {
        let wanted = min(RAMSettings.processCount, processRows.count)
        guard wanted > 0 else {
            processRows.forEach { $0.isHidden = true }
            return
        }
        ProcessMemory.top(wanted) { [weak self] entries in
            guard let self else { return }
            for (index, row) in self.processRows.enumerated() {
                if index < entries.count {
                    let entry = entries[index]
                    row.set(name: entry.name, pid: entry.pid,
                            value: Readings.bytes(entry.bytes))
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
        }
    }
}

// MARK: - Dashboard

/// In this file because the latest sample is private to it.
extension RAMModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        guard let usage = latest else { return nil }
        let pressure = latestPressure
        var facts = [DashboardReport.Fact(
            label: localized("Used"),
            value: localized("%0 of %1", Readings.bytes(usage.used), Readings.bytes(usage.total)))]
        facts.append(.init(label: localized("Compressed"), value: Readings.bytes(usage.compressed)))
        if let swap = latestSwap {
            facts.append(.init(label: localized("Swap"), value: Readings.bytes(swap.used)))
        }
        return DashboardReport(
            value: "\(Int((usage.percent * 100).rounded()))%",
            // The pressure, named as pressure. The percentage above it is
            // how full memory is, which on a Mac is not the same question.
            caption: localized("Pressure: %0", localized(pressure.label)),
            severity: pressure == .critical ? .critical : pressure == .warning ? .warning : .calm,
            facts: facts,
            history: usageHistory,
            fill: usage.percent,
            signal: .memory(pressure: pressure.rawValue))
    }
}
