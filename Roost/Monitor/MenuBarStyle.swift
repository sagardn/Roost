import AppKit

/// A shape a reading can take in the menu bar.
///
/// Six, because six is what the module system being replaced offered, and a
/// migration that quietly drops five of them is not a migration. The raw
/// values are the names already written to disk, so a Mac that has been
/// running Roost keeps the shapes it was set to without anything being
/// rewritten on first launch.
enum MenuBarStyle: String, CaseIterable {
    /// The module's name, three letters stacked down the bar. No value.
    case label = "label"
    /// A small caption over the figure. The default, and the only one the
    /// independent monitor drew before this.
    case mini = "mini"
    /// Recent history, filled to the baseline, in a box.
    case lineChart = "line_chart"
    /// One bar per core, or one bar for a module with a single reading.
    case barChart = "bar_chart"
    /// A ring, split into the parts the load is made of.
    case pieChart = "pie_chart"
    /// A half-gauge, filling left to right.
    case tachometer = "tachometer"
    /// Two short figures stacked -- used over free. Only modules with a pair
    /// worth stacking offer it.
    case pair = "memory"
    /// The same two figures with arrows: up over down. Network's.
    case rates = "speed"
    /// Upload above the line, download below, on one scale. Network's.
    case trafficChart = "network_chart"
    /// An SF Symbol, for a module whose reading is a place to go rather than
    /// a number: the clipboard. Offered only by a module that names one.
    case symbol = "symbol"

    /// The shapes that only some modules can fill, which the shared default
    /// list leaves out.
    static let special: Set<MenuBarStyle> = [.pair, .rates, .trafficChart, .symbol]

    /// What the settings page calls it.
    var title: String {
        switch self {
        case .label:      return localized("Name")
        case .mini:       return localized("Figure")
        case .lineChart:  return localized("Line chart")
        case .barChart:   return localized("Bar chart")
        case .pieChart:   return localized("Ring")
        case .tachometer: return localized("Gauge")
        case .pair:         return localized("Used and free")
        case .rates:        return localized("Rates")
        case .trafficChart: return localized("Traffic chart")
        case .symbol:       return localized("Icon")
        }
    }
}

/// Which shapes a module is showing.
///
/// Stored under `<Module>_widget` as a comma-separated list -- the key and the
/// format the old module system used, read and written in place. Several at
/// once is deliberate: that system allowed it, people use it, and a reading
/// drawn twice in two shapes still only samples once.
enum MenuBarStyles {

    /// Reads the stored list.
    ///
    /// Unknown names are dropped rather than refused. A build that no longer
    /// offers a shape, or a settings file touched by hand, must not clear
    /// somebody's menu bar -- and the empty result that would cause is
    /// indistinguishable from "show nothing", which is a thing a user can
    /// legitimately choose. So an unreadable value falls back to the
    /// default, and a readable one that mentions one shape Roost knows keeps
    /// that shape.
    static func stored(for module: String, default fallback: [MenuBarStyle] = [.mini]) -> [MenuBarStyle] {
        guard let raw = UserDefaults.standard.string(forKey: key(module)) else { return fallback }

        // An explicit empty string is a choice: nothing in the menu bar.
        if raw.isEmpty { return [] }

        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = names.compactMap { MenuBarStyle(rawValue: $0) }
        // Every name unrecognised means the value is not ours -- a shape from
        // another module's vocabulary, or a typo. Better the default than an
        // empty bar nobody asked for.
        return known.isEmpty ? fallback : deduplicated(known)
    }

    static func store(_ styles: [MenuBarStyle], for module: String) {
        Preferences.shared.set(key(module),
                               deduplicated(styles).map { $0.rawValue }.joined(separator: ","))
    }

    /// Where the list is stored. The key the old module system wrote.
    static func key(_ module: String) -> String { "\(module)_widget" }

    /// In `MenuBarStyle.allCases` order, not the stored order.
    ///
    /// The stored order came from the sequence somebody ticked the boxes in,
    /// which is not an order anyone chose to look at. Drawing in a fixed
    /// order means turning a shape off and on again puts it back where it
    /// was.
    private static func deduplicated(_ styles: [MenuBarStyle]) -> [MenuBarStyle] {
        MenuBarStyle.allCases.filter { styles.contains($0) }
    }
}

/// Sizes every shape is drawn to.
///
/// One place, because the shapes have to agree: a row of them with different
/// vertical insets reads as misaligned however carefully each one is drawn on
/// its own.
enum MenuBarMetrics {

    /// Breathing room on each side of a shape.
    static let padding: CGFloat = 2

    /// The height every shape is drawn for: 22, fixed.
    ///
    /// It was read from `mainMenu?.menuBarHeight`, falling back to 22. Roost
    /// had no main menu, so that was nil and 22 is what every shape was
    /// designed, measured and shipped at. The day a main menu was added it
    /// answered the real bar's height -- taller on a Mac with a notch -- and
    /// every item drew its figures below the space the status item gives
    /// them: the names showed and the numbers were cut off.
    static var height: CGFloat { 22 }

    /// How tall a drawn shape is: the bar, less a point of clearance top and
    /// bottom so nothing touches the screen edge or the item below it.
    static var drawHeight: CGFloat { height - 6 }

    /// The widest a figure can be, measured rather than budgeted: a semibold
    /// "100%", which is how a flagged figure is drawn. The shape this
    /// replaced allowed 31pt and clipped.
    static let figureWidth: CGFloat =
        ("100%" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width + padding * 2

    /// One glyph of the stacked name. "W" is the widest letter at this size.
    static let labelWidth: CGFloat =
        ("W" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .regular)
        ]).width + padding * 2

    /// An icon at the size of the menu bar's own -- macOS draws its status
    /// icons at about 16pt in a 22pt-tall bar -- with the usual padding.
    static let symbolPointSize: CGFloat = 14
    static let symbolWidth: CGFloat = 18 + padding * 2

    /// A point for every two samples at the default two-minute history, so
    /// the chart is the width the one it replaces was.
    static let chartWidth: CGFloat = 32

    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 1

    /// Bars are sized to how many there are, with a floor so a single bar is
    /// still a bar and a ceiling so a 32-core machine does not take a third
    /// of the menu bar.
    static func barChartWidth(bars: Int) -> CGFloat {
        let bars = max(1, bars)
        let wanted = CGFloat(bars) * barWidth + CGFloat(bars - 1) * barGap
        return min(max(wanted, 10), 118) + padding * 2
    }

    /// The ring and the gauge are square, to the drawing height.
    static var dialWidth: CGFloat { drawHeight + padding * 2 }

    /// How far a coloured mark moves toward the bar's ink to stay readable
    /// on a wallpaper. Picked by eye from a side-by-side on a green bar,
    /// not derived: enough to lift the colours off a mid-tone wallpaper,
    /// little enough that they stay recognisably teal, amber and red.
    static let legibleLift: CGFloat = 0.4

    /// Two rates with their arrows, plus the arrow column.
    ///
    /// Measured against every shape a rate can take, not one guess at the
    /// widest. "999 MB/s" was the guess, and it is 42pt where "17.0 KB/s" is
    /// 43: the figure wrapped, and the second line -- the unit -- fell off the
    /// bottom of the item. A decimal and a four-figure count (sizes run to
    /// 1023 before the unit steps) are both wider than three whole digits,
    /// and 99.95 rounds to "100.0", which is wider than either.
    static let widestRates = ["1023 B/s", "100.0 KB/s", "1023 KB/s",
                              "100.0 MB/s", "1023 MB/s", "100.0 GB/s", "1023 GB/s"]

    static let ratesWidth: CGFloat =
        9 + widestRates.map {
            ($0 as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            ]).width.rounded(.up)
        }.max()! + padding * 2

    /// Two stacked figures. Measured against the widest pair a memory
    /// reading can hold -- "128.0 GB" at 9pt -- rather than the 50 points the
    /// shape this replaces allowed, which clipped on a machine with that much.
    static let pairWidth: CGFloat =
        ("128.0 GB" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]).width + padding * 2

    static func width(of style: MenuBarStyle, bars: Int) -> CGFloat {
        switch style {
        case .label:      return labelWidth
        case .mini:       return figureWidth
        case .lineChart:  return chartWidth + padding * 2
        case .barChart:   return barChartWidth(bars: bars)
        case .pieChart,
             .tachometer: return dialWidth
        case .pair:         return pairWidth
        case .rates:        return ratesWidth
        case .trafficChart: return chartWidth + padding * 2
        case .symbol:       return symbolWidth
        }
    }
}
