import Foundation

/// Where the first-run window is, and what choosing a preset writes.
///
/// Separated from the window because the window is shown exactly once per
/// installation. Everything here used to live inside an `NSStackView`
/// subclass that cannot be instantiated without a screen, which meant the
/// only part of first-run anybody could check was whether it crashed — and
/// the part worth checking is not the drawing, it is the fourteen preference
/// writes that decide what somebody's menu bar looks like for the rest of the
/// time they use the app.

// MARK: - The pages

/// The six pages, in the order they are shown.
///
/// `Int` raw values because `--render setup:<n>` addresses them by number and
/// that is the only interface anyone has to the later pages.
enum SetupPage: Int, CaseIterable {
    case welcome
    case preset
    /// Accessibility, explained before the first shortcut needs it.
    case windowControl
    case loginItem
    case updates
    case done
}

/// Which page is showing, and what the two footer buttons should say.
///
/// A stored page rather than a lookup. The version this replaces asked the
/// view hierarchy — it took the first subview of the content area, searched
/// the page array for it by identity, and worked forward or back from the
/// index it found. That is a question with an answer the flow already knows,
/// asked of a structure that can give the wrong one: a page not yet added, or
/// added twice, silently stopped both buttons working.
struct SetupFlow {

    private(set) var page: SetupPage = .welcome

    init(page: SetupPage = .welcome) { self.page = page }

    /// False on the first page only.
    var canGoBack: Bool { page != SetupPage.allCases.first }

    /// The last page's button says Finish, because it closes the window
    /// rather than showing a seventh page.
    var isFinish: Bool { page == SetupPage.allCases.last }

    var nextTitle: String { isFinish ? localized("Finish") : localized("Next") }

    var nextTooltip: String { isFinish ? localized("Finish setup") : localized("Next page") }

    /// What pressing Next does.
    enum Advance: Equatable {
        case show(SetupPage)
        /// The last page: the window closes and the app starts.
        case finish
    }

    @discardableResult
    mutating func advance() -> Advance {
        guard let next = SetupPage(rawValue: page.rawValue + 1) else { return .finish }
        page = next
        return .show(next)
    }

    @discardableResult
    mutating func goBack() -> SetupPage {
        if let previous = SetupPage(rawValue: page.rawValue - 1) { page = previous }
        return page
    }
}

// MARK: - The presets

/// One preference the first-run window writes.
///
/// Spelled out as data rather than performed directly, so a test can hold the
/// exact key and the exact string. Both matter and neither is obvious from
/// reading the code that consumes them: `<Module>_state` and `<Module>_widget`
/// are what every module reads at launch, `_widget` holds `MenuBarStyle`'s raw
/// values rather than its case names, and a Mac that has been running Roost
/// has them already. Getting either wrong resets a menu bar somebody arranged.
enum SetupWrite: Equatable {
    case flag(key: String, value: Bool)
    case text(key: String, value: String)

    var key: String {
        switch self {
        case .flag(let key, _), .text(let key, _): return key
        }
    }
}

/// A starting set of modules, and the shape each one begins in.
struct SetupPreset: Equatable {
    let name: String
    let items: [Item]

    struct Item: Equatable {
        let module: String
        let style: MenuBarStyle

        init(_ module: String, _ style: MenuBarStyle) {
            self.module = module
            self.style = style
        }
    }

    /// The modules first-run offers, in menu bar order.
    ///
    /// No Battery and no Bluetooth: macOS shows both already, so Roost is not
    /// in that business. No Clock either — that module went before those two.
    static let modules = ["CPU", "GPU", "RAM", "Disk", "Sensors", "Network"]

    /// Offered in this order, with the first one selected.
    static let all: [SetupPreset] = [
        SetupPreset(name: "Default", items: [
            Item("CPU", .mini), Item("RAM", .mini),
            Item("Disk", .mini), Item("Network", .rates)
        ]),
        SetupPreset(name: "Basic", items: [
            Item("CPU", .mini), Item("RAM", .mini)
        ]),
        SetupPreset(name: "Recommended", items: [
            Item("CPU", .mini), Item("RAM", .barChart),
            Item("Disk", .barChart), Item("Network", .rates)
        ]),
        SetupPreset(name: "Extended", items: [
            Item("CPU", .lineChart), Item("GPU", .mini),
            Item("RAM", .barChart), Item("Disk", .barChart),
            Item("Sensors", .label), Item("Network", .rates)
        ])
    ]

    static let defaultIndex = 0

    /// Exactly what choosing this preset writes, in `modules` order.
    ///
    /// Every module is named, not only the ones the preset includes: somebody
    /// clicking Basic after clicking Extended has to end up with Sensors
    /// switched off, and a preset that only wrote what it wanted would leave
    /// the previous choice standing.
    ///
    /// A module that is off gets no `_widget` write. Its shape is left where
    /// it was, so switching it on again later restores what it looked like
    /// rather than resetting it to a figure.
    func writes() -> [SetupWrite] {
        let styles = Dictionary(uniqueKeysWithValues: items.map { ($0.module, $0.style) })
        return SetupPreset.modules.flatMap { module -> [SetupWrite] in
            guard let style = styles[module] else {
                return [.flag(key: "\(module)_state", value: false)]
            }
            return [.flag(key: "\(module)_state", value: true),
                    .text(key: MenuBarStyles.key(module), value: style.rawValue)]
        }
    }
}
