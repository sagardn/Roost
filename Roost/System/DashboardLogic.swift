import Foundation

// The parts of the Dashboard that are decisions rather than drawing: which
// cards exist and in what order, what counts as a problem worth a line, what
// to call this release of macOS, and how much of a serial number to show.
//
// Kept apart from the views so each of them can be checked against values
// written down -- see Tools/dashboard-test.swift. Nothing here samples
// anything: the readings arrive from the modules that already took them.

// MARK: - Cards

/// A card on the Dashboard, by the module it reports for.
///
/// The raw value is the module's name, which is also how a card finds the
/// module page it opens and what the stored layout holds. A module that is
/// renamed would orphan its card's stored position, and `DashboardLayout`
/// drops an unknown name rather than failing on it.
enum DashboardCard: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "RAM"
    case disk = "Disk"
    case network = "Network"
    /// Not a module: the battery's health is read by the Dashboard itself,
    /// see `BatteryHealth`. The name is only this card's in the stored
    /// layout -- nothing reads the `Battery_state` key the removed module
    /// left behind.
    case battery = "Battery"
    case gpu = "GPU"
    case sensors = "Sensors"

    var id: String { rawValue }
    var module: String { rawValue }

    /// What the card is called on screen, which is not always the module's
    /// name: "RAM" is a menu bar label, and on a card of its own the reading
    /// is memory.
    /// What the health summary reads from this card's module, named as
    /// what it measures: "memory pressure", not "memory" -- the summary is
    /// about pressure, and saying "memory" would claim it judged how full.
    var basisName: String {
        switch self {
        case .cpu:     return localized("CPU load")
        case .memory:  return localized("memory pressure")
        case .disk:    return localized("free space")
        case .network: return localized("the network link")
        case .battery: return localized("Battery")
        case .gpu:     return localized("GPU")
        case .sensors: return localized("Sensors")
        }
    }

    var title: String {
        switch self {
        case .cpu:     return localized("CPU")
        case .memory:  return localized("Memory")
        // Storage on the card: what somebody looks for is how much room is
        // left, and the module that answers it is still called Disk.
        case .disk:    return localized("Storage")
        case .network: return localized("Network")
        case .battery: return localized("Battery health")
        case .gpu:     return localized("GPU")
        case .sensors: return localized("Sensors")
        }
    }
}

/// Which cards the Dashboard shows, and in what order.
///
/// Stored as two lists of names rather than one list with a flag each, so a
/// card that is added in a later release can be told apart from one the user
/// hid: it is in neither list, and arrives where the default puts it.
struct DashboardLayout: Equatable {
    var order: [DashboardCard]
    var hidden: Set<DashboardCard>

    /// The four the brief asked for up front. GPU and Sensors are there to
    /// be switched on, not shown by default: on a laptop the GPU reads 0-3%
    /// all day, and Sensors' headline is one die among thirty-odd.
    static let standard = DashboardLayout(order: DashboardCard.allCases,
                                          hidden: [.gpu, .sensors])

    var visible: [DashboardCard] { order.filter { !hidden.contains($0) } }

    var isStandard: Bool { self == Self.standard }

    /// The layout from what was stored.
    ///
    /// Unknown names are dropped and duplicates collapse to their first
    /// place. A card the stored order does not mention is new since it was
    /// saved: it goes in at its default position relative to the cards
    /// around it, and takes its default visibility, rather than appearing
    /// hidden or jumping to the end.
    static func resolve(order stored: [String]?, hidden storedHidden: [String]?) -> DashboardLayout {
        guard let stored else { return standard }

        var order: [DashboardCard] = []
        for name in stored {
            guard let card = DashboardCard(rawValue: name), !order.contains(card) else { continue }
            order.append(card)
        }
        let missing = DashboardCard.allCases.filter { !order.contains($0) }
        for card in missing {
            // After the nearest card that precedes it in the default order
            // and is already placed; at the front if none is.
            let defaults = DashboardCard.allCases
            let before = defaults[..<defaults.firstIndex(of: card)!].reversed()
            if let anchor = before.first(where: order.contains),
               let index = order.firstIndex(of: anchor) {
                order.insert(card, at: index + 1)
            } else {
                order.insert(card, at: 0)
            }
        }

        var hidden = Set((storedHidden ?? []).compactMap(DashboardCard.init(rawValue:)))
        hidden.formUnion(missing.filter { standard.hidden.contains($0) })
        return DashboardLayout(order: order, hidden: hidden)
    }

    var storedOrder: [String] { order.map(\.rawValue) }
    /// Sorted, so the stored value does not churn with set ordering.
    var storedHidden: [String] { hidden.map(\.rawValue).sorted() }

    /// The layout with one card moved `offset` places, clamped to the ends.
    func moving(_ card: DashboardCard, by offset: Int) -> DashboardLayout {
        guard let from = order.firstIndex(of: card) else { return self }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return self }
        var copy = self
        copy.order.remove(at: from)
        copy.order.insert(card, at: to)
        return copy
    }

    func setting(_ card: DashboardCard, shown: Bool) -> DashboardLayout {
        var copy = self
        if shown { copy.hidden.remove(card) } else { copy.hidden.insert(card) }
        return copy
    }
}

// MARK: - Storage

/// What the Storage panel draws: the volume's three figures, and what the
/// disk is doing.
///
/// Bytes rather than formatted strings, so the chart and the words beside it
/// are drawn from one set of numbers and cannot disagree.
struct StorageDetail: Equatable {
    let volume: String
    let total: UInt64
    /// What Finder calls available: free for important use, after purgeable.
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }

    /// Bytes per second on this tick. nil where the disk has not been
    /// sampled twice yet, so there is no rate to give.
    let readRate: Double?
    let writeRate: Double?
    /// Recent rates, oldest first, on one shared scale (0...1).
    let readHistory: [Double]
    let writeHistory: [Double]

    /// 0...1, or nil for a reading that cannot be drawn: no capacity, or
    /// figures that do not add up. A chart of nil is a dash, never an empty
    /// ring that reads as a disk with nothing on it.
    var usedFraction: Double? {
        guard total > 0, free <= total else { return nil }
        let fraction = Double(used) / Double(total)
        return fraction.isFinite ? min(max(fraction, 0), 1) : nil
    }
}

// MARK: - Grid

enum DashboardGrid {
    /// The narrowest a card can be and still hold "9.9 GB of 16.0 GB"
    /// beside its label, measured in the 720pt window's two-column grid.
    static let minimumCardWidth: CGFloat = 220
    static let maximumColumns = 4

    /// How many columns `count` cards get in `width` points.
    ///
    /// As many as fit, but not a number that leaves a row short when a
    /// smaller one would not: an adaptive grid put the four standard cards
    /// three and one at 1100pt, Network alone on a row of its own. A count
    /// with no such divisor -- five cards -- takes as many as fit.
    static func columns(for count: Int, width: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0, width.isFinite, width > 0 else { return 1 }
        let fit = Int((width + spacing) / (minimumCardWidth + spacing))
        let most = max(1, min(fit, count, maximumColumns))
        if count % most == 0 { return most }
        let even = (2..<most).reversed().first { count % $0 == 0 }
        return even ?? most
    }
}

// MARK: - Health

/// How the Mac is doing, in three steps.
///
/// Deliberately three and not a score. A number out of 100 would have to be
/// made of weights nobody could defend; three steps each map to something a
/// module already measured.
enum HealthLevel: Int, Comparable {
    case normal, elevated, attention

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What one module's reading says about the Mac's health.
///
/// Raw values only, as the module measured them: the rules about what they
/// mean are `Health`'s, so they can be tested without a module.
enum HealthSignal: Equatable {
    /// The mean of the last few seconds of load, 0...1, and whether macOS is
    /// slowing the processor to cool it.
    case cpu(recentLoad: Double, throttled: Bool)
    /// The kernel's own pressure level: 1 normal, 2 warning, 4 critical, the
    /// values `kern.memorystatus_vm_pressure_level` reports.
    case memory(pressure: Int)
    /// Fraction of the watched volume in use, and the bytes still free.
    case disk(used: Double, free: UInt64, volume: String)
    /// Whether the primary interface is up. Not whether the internet
    /// answers: that probe runs only while the Network popup is open, and a
    /// stale answer here would be a claim about a network nobody checked.
    case network(linkUp: Bool)
    // No temperature case, deliberately. The first version had one, fed
    // by the Sensors module's hottest reading, and its first render on an
    // idle M2 Air said "Running very hot: TpOA reads 102 °C". TpOA is one
    // of the SMC keys nobody can name (see docs/ARCHITECTURE.md ▸ What
    // Sensors does not reproduce), and an unnamed key is not a die. Whether
    // the Mac is too hot is macOS's call, made in `thermalState`, and that
    // reaches this through `.cpu(throttled:)`.
}

struct HealthIssue: Equatable, Identifiable {
    let level: HealthLevel
    /// The module page that explains it.
    let module: String
    let title: String
    let explanation: String

    var id: String { module + title }
}

enum Health {

    /// Seconds of CPU history the verdict averages over. One busy second is
    /// an app launching; ten is something that is still going.
    static let cpuWindow = 10

    /// The issues these signals add up to, worst first.
    ///
    /// The thresholds are the ones every other part of Roost uses
    /// (`SeverityBands`), so the Dashboard cannot call something a problem
    /// that the menu bar draws as calm. Load in the warning band is not an
    /// issue at all: a Mac at 60% is a Mac doing what it was asked.
    static func issues(_ signals: [HealthSignal]) -> [HealthIssue] {
        var found: [HealthIssue] = []
        for signal in signals {
            switch signal {
            case let .cpu(load, throttled):
                if throttled {
                    found.append(HealthIssue(
                        level: .attention, module: "CPU",
                        title: localized("The Mac is slowing down to cool off"),
                        explanation: localized("macOS has reduced the processor's speed because it is running hot. Quitting busy apps lets it recover.")))
                } else if load.isFinite, load >= SeverityBands.load.critical {
                    found.append(HealthIssue(
                        level: .elevated, module: "CPU",
                        title: localized("The processor is busy"),
                        explanation: localized("CPU load has averaged %0 over the last %1 seconds. The CPU page lists what is using it.",
                                               "\(Int((load * 100).rounded()))%", "\(cpuWindow)")))
                }

            case let .memory(pressure):
                // The kernel's level, never the percentage: macOS fills spare
                // memory with cache on purpose, so "82% used" is a healthy
                // Mac, and pressure is what says otherwise.
                if pressure >= 4 {
                    found.append(HealthIssue(
                        level: .attention, module: "RAM",
                        title: localized("Memory pressure is critical"),
                        explanation: localized("macOS is short of memory, and apps may slow down while it makes room. Quitting apps you are not using helps.")))
                } else if pressure >= 2 {
                    found.append(HealthIssue(
                        level: .elevated, module: "RAM",
                        title: localized("Memory pressure is raised"),
                        explanation: localized("macOS is compressing memory to make room. Nothing needs doing unless apps start to feel slow.")))
                }

            case let .disk(used, free, volume):
                guard used.isFinite else { continue }
                let zone = SeverityBands.disk.zone(used)
                guard zone > 0 else { continue }
                found.append(HealthIssue(
                    level: zone >= 2 ? .attention : .elevated, module: "Disk",
                    title: zone >= 2 ? localized("%0 is almost full", volume)
                                     : localized("%0 is getting full", volume),
                    explanation: localized("%0 free. Free up space can find large files and apps you no longer use.",
                                           Readings.size(free))))

            case let .network(linkUp):
                if !linkUp {
                    found.append(HealthIssue(
                        level: .elevated, module: "Network",
                        title: localized("No network connection"),
                        explanation: localized("No network interface is up. Wi-Fi may be off, or the cable unplugged.")))
                }
            }
        }
        // Stable: issues of the same level keep the order their cards have.
        return found.enumerated()
            .sorted { ($1.element.level, $0.offset) < ($0.element.level, $1.offset) }
            .map(\.element)
    }

    static func level(_ issues: [HealthIssue]) -> HealthLevel {
        issues.map(\.level).max() ?? .normal
    }

    /// One line for the header.
    static func summary(_ issues: [HealthIssue], watching: Int) -> String {
        guard watching > 0 else { return localized("No modules are on, so there is nothing to report") }
        switch issues.count {
        case 0:  return localized("Everything looks normal")
        case 1:  return issues[0].title
        default: return localized("%0 things to look at", "\(issues.count)")
        }
    }

    /// The mean of the last `cpuWindow` samples, or nil until there are any.
    static func recentMean(_ history: [Double]) -> Double? {
        let tail = history.suffix(cpuWindow).filter(\.isFinite)
        guard !tail.isEmpty else { return nil }
        return tail.reduce(0, +) / Double(tail.count)
    }
}
