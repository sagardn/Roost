import Foundation

/// What a module tells a Dashboard card.
///
/// Built from the sample the module's `menuBarContent()` already took on the
/// menu bar tick. Nothing here samples: the Dashboard is a second place to
/// look at the readings, and a second sampler beside the first would have
/// been a second source of truth -- the CPU's tick counters, differenced by
/// two callers, would each have seen half the load.
struct DashboardReport {

    struct Fact: Hashable {
        let label: String
        let value: String
    }

    /// The figure the card is about: "23%", "↓ 1.2 MB/s".
    var value: String
    /// A second figure of equal weight, for a reading that is two things at
    /// once: upload beside download. Each is (label, figure).
    var pair: (first: (String, String), second: (String, String))?
    /// The verdict in a word or two, the same words the popup uses: "Light
    /// load", "Pressure normal". Always text, so the state never rests on
    /// colour alone.
    var caption: String
    var severity: MenuBarReading.Severity = .calm
    /// Two or three supporting figures; the card draws at most three. Storage
    /// has four, and draws none of them on a card: its panel draws
    /// `storage` instead, and the facts are what VoiceOver and the
    /// not-measured card fall back on.
    var facts: [Fact] = []
    /// Recent history, oldest first, 0...1.
    var history: [Double] = []
    /// A second series against the first, upload under download. Normalised
    /// on the same scale as `history`.
    var mirror: [Double]?
    /// How full something is, 0...1, for a capacity bar: a disk, memory.
    var fill: Double?
    /// What the health summary should know.
    var signal: HealthSignal?
    /// The watched volume in full, for the Storage panel's chart and
    /// breakdown. Only the Disk module sets it.
    var storage: StorageDetail?
    /// Set when the module is running but this Mac cannot give the reading
    /// -- a GPU driver that publishes no utilization. The card says this
    /// instead of drawing a zero.
    var unavailable: String?

    /// What VoiceOver reads for the whole card.
    var spoken: String {
        let figures = pair.map { ["\($0.first.0) \($0.first.1)", "\($0.second.0) \($0.second.1)"] } ?? [value]
        return (figures + [caption] + facts.map { "\($0.label) \($0.value)" }).joined(separator: ", ")
    }
}

/// A module that can describe its latest sample to the Dashboard.
///
/// nil means the module has not sampled yet -- just switched on, or not
/// being ticked because nothing of it is in the menu bar. The card says which.
protocol DashboardReporting: AnyObject {
    func dashboardReport() -> DashboardReport?
}

extension Notification.Name {
    /// Posted after every menu bar tick, once the modules have sampled.
    static let monitorDidTick = Notification.Name("RoostMonitorDidTick")
}

extension Array where Element == Double {
    /// Scaled so the largest value is 1, for a chart of rates with no fixed
    /// ceiling. A flat line of zeros stays zeros rather than dividing by them.
    func normalised(against peak: Double? = nil) -> [Double] {
        let top = Swift.max(peak ?? (self.max() ?? 0), 0)
        guard top > 0, top.isFinite else { return map { _ in 0 } }
        return map { $0.isFinite ? Swift.min(Swift.max($0 / top, 0), 1) : 0 }
    }
}
