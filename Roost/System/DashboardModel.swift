import AppKit
import Combine
import IOKit.ps

/// What the Dashboard shows, gathered from the modules on each menu bar tick.
///
/// It owns no timer and samples nothing. `MonitorBar` posts after every tick
/// and this reads what the modules just measured, so the Dashboard costs a
/// few dictionary lookups a second while it is on screen and nothing at all
/// while it is not: `isActive` is false whenever the pane is out of a window.
final class DashboardModel: ObservableObject {

    /// What one card can say.
    enum CardState {
        /// Switched off in the sidebar.
        case off
        /// On, but not being sampled: the tick samples only what the menu bar
        /// draws, and every shape of this module is switched off.
        case notSampled
        /// On and sampled, but no sample has arrived yet.
        case waiting
        /// This Mac does not have the hardware.
        case unsupported
        case reading(DashboardReport)
    }

    @Published private(set) var states: [DashboardCard: CardState] = [:]
    @Published private(set) var issues: [HealthIssue] = []
    /// How many modules the health summary is drawing on.
    @Published private(set) var watching = 0
    /// Which, in card order: the ones whose reading carries a health signal.
    @Published private(set) var basis: [DashboardCard] = []
    @Published private(set) var uptime = "—"

    // MARK: Battery

    /// The internal battery's charge, or nil on a Mac without one -- which is
    /// how the card knows to stay away.
    @Published private(set) var charge: BatteryHealth.Charge?
    /// The system's own health report, once it has been read.
    @Published private(set) var health: BatteryHealth.Report?
    /// Whether the report has been asked for and answered, so a card can tell
    /// "still reading" from "the system does not say".
    @Published private(set) var healthRead = false
    private var healthReadAt: Date?
    private var powerSource: CFRunLoopSource?
    /// A battery's wear moves over weeks. Half an hour between reports, and
    /// only while the Dashboard is open.
    static let healthInterval: TimeInterval = 30 * 60

    @Published var layout: DashboardLayout {
        didSet {
            guard layout != oldValue else { return }
            Preferences.shared.set(Self.orderKey, layout.storedOrder)
            Preferences.shared.set(Self.hiddenKey, layout.storedHidden)
        }
    }

    @Published var showsDetails: Bool {
        didSet { Preferences.shared.set(Self.detailsKey, showsDetails) }
    }

    /// Opens a page by name, the way the sidebar does.
    let open: (String) -> Void
    /// Switches a module on, the way the sidebar's switch does.
    let enable: (String) -> Void

    private static let orderKey = "Dashboard_cards"
    private static let hiddenKey = "Dashboard_hidden"
    private static let detailsKey = "Dashboard_details"

    private var observers: [NSObjectProtocol] = []
    /// Published so the page's own sampler can start and stop with it,
    /// rather than keeping a second idea of whether the Dashboard is up.
    @Published var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? subscribe() : unsubscribe()
        }
    }

    init(open: @escaping (String) -> Void, enable: @escaping (String) -> Void) {
        self.open = open
        self.enable = enable
        let prefs = Preferences.shared
        layout = DashboardLayout.resolve(order: prefs.strings(Self.orderKey),
                                         hidden: prefs.strings(Self.hiddenKey))
        showsDetails = prefs.bool(Self.detailsKey, default: false)
        refresh()
    }

    deinit { unsubscribe() }

    func restoreDefaultLayout() { layout = .standard }

    // MARK: - Reading

    private func subscribe() {
        refreshBattery()
        watchPowerSource()
        refresh()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .monitorDidTick, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            },
            // A switch flipped in the sidebar or a menu changes a card from
            // "off" without waiting for a tick -- and when the last module
            // goes off there are no more ticks to wait for.
            center.addObserver(forName: .toggleModule, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        ]
    }

    private func unsubscribe() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
    }

    /// The charge, now, and the health report if it is due.
    func refreshBattery() {
        charge = BatteryHealth.currentCharge()
        guard charge != nil else { return }
        if let at = healthReadAt, Date().timeIntervalSince(at) < Self.healthInterval { return }
        healthReadAt = Date()
        BatteryHealth.readReport { [weak self] report in
            self?.health = report
            self?.healthRead = true
        }
    }

    /// Told by the system when the power source changes -- a charger plugged
    /// in, a percent gone -- instead of asking it on a timer. IOKit posts it
    /// at most once a minute or so on a battery and on every plug and unplug.
    private func watchPowerSource() {
        guard powerSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<DashboardModel>.fromOpaque(context).takeUnretainedValue()
            model.refreshBattery()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    func refresh() {
        var states: [DashboardCard: CardState] = [:]
        var signals: [HealthSignal] = []
        var watching = 0
        var basis: [DashboardCard] = []

        for card in DashboardCard.allCases where card != .battery {
            guard let module = ModuleRegistry.shared.named(card.module), module.isAvailable else {
                states[card] = .unsupported
                continue
            }
            guard module.isEnabled else {
                states[card] = .off
                continue
            }
            guard MonitorBar.shared.isShowing(card.module) else {
                states[card] = .notSampled
                continue
            }
            guard let report = (module as? DashboardReporting)?.dashboardReport() else {
                states[card] = .waiting
                continue
            }
            watching += 1
            if let signal = report.signal {
                signals.append(signal)
                basis.append(card)
            }
            states[card] = .reading(report)
        }

        self.states = states
        self.watching = watching
        self.basis = basis
        self.issues = Health.issues(signals)
        uptime = DeviceInfo.bootDate.map { Uptime.describe(seconds: Date().timeIntervalSince($0)) } ?? "—"
    }

    var level: HealthLevel { Health.level(issues) }
    var summary: String { Health.summary(issues, watching: watching) }
}
