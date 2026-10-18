import AppKit

/// What the application shell needs of the network module.
extension NetworkModule: RoostModule {

    var moduleName: String { "Network" }

    /// Every Mac has an interface, even if nothing is plugged into it.
    var isAvailable: Bool { true }

    var isOnByDefault: Bool { true }

    var hasPreview: Bool { false }

    var isEnabled: Bool {
        get { NetworkSettings.isEnabled }
        set {
            guard newValue != NetworkSettings.isEnabled else { return }
            NetworkSettings.isEnabled = newValue
            newValue ? MonitorBar.shared.show(self) : MonitorBar.shared.hide(moduleName)
        }
    }

    func start() {
        guard isEnabled else { return }
        MonitorBar.shared.show(self)
    }

    func stop() {
        willStop()
        MonitorBar.shared.hide(moduleName)
    }

    var popupShortcut: [UInt16] { NetworkSettings.popupShortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { NetworkSettingsPage() }
}

/// Network's own preferences, under the keys the module it replaces used.
enum NetworkSettings {
    private static let prefs = Preferences.shared

    static var isEnabled: Bool {
        get { prefs.bool("Network_state", default: true) }
        set { prefs.set("Network_state", newValue) }
    }

    /// Whether to ask a public service what this machine's address looks like
    /// from outside. Off means Roost makes no request of its own at all.
    static var looksUpPublicIP: Bool {
        get { prefs.bool("Network_publicIP", default: true) }
        set { prefs.set("Network_publicIP", newValue) }
    }

    /// How many processes the popup lists. Zero stops `nettop` entirely,
    /// which is by far the most expensive thing this module does.
    static var processCount: Int {
        get { prefs.int("Network_processes", default: 8) }
        set { prefs.set("Network_processes", newValue) }
    }

    static var popupShortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "Network_popupShortcut") as? [Int])?
            .map { UInt16($0) } ?? []
    }
}

/// Something about the link that is worth being told has changed.
///
/// Not thresholds: a link does not cross a line, it becomes something else.
/// Each one is a switch, under the keys the module being replaced wrote.
enum NetworkAlert: String, CaseIterable {
    case connection
    case interface
    case localIP
    case publicIP
    case wifi

    var title: String {
        switch self {
        case .connection: return localized("Connection comes or goes")
        case .interface:  return localized("Interface changes")
        case .localIP:    return localized("Local address changes")
        case .publicIP:   return localized("Public address changes")
        case .wifi:       return localized("Wi-Fi network changes")
        }
    }

    var stateKey: String { "Network_notifications_\(rawValue)_state" }

    var isWatched: Bool {
        get { Preferences.shared.bool(stateKey, default: false) }
        nonmutating set { Preferences.shared.set(stateKey, newValue) }
    }

    var notificationID: String { "Roost_Network_\(rawValue)" }

    /// How many times in a row a new answer has to agree with itself.
    ///
    /// Two for the connection and three for the public address, which is what
    /// the module this replaces waited for, and for the same reason: a probe
    /// through a struggling link fails occasionally without the link being
    /// down, and an address read through one comes back wrong now and then.
    var confirmations: Int {
        switch self {
        case .connection:
            return max(1, Preferences.shared.int("Network_notifications_connection_threshold",
                                                 default: 2))
        case .publicIP: return 3
        default:        return 1
        }
    }
}

/// Watches the link for the changes that are switched on.
///
/// Driven from the module's own sample, like every other watcher here, so a
/// switch that is off costs nothing at all -- including, for the public
/// address, not making the request.
final class NetworkAlerts {

    private var connection = ChangeTracker<Bool>(confirmations: 2)
    private var interface = ChangeTracker<String>()
    private var localIP = ChangeTracker<String>()
    private var publicIP = ChangeTracker<String>(confirmations: 3)
    private var wifi = ChangeTracker<String>()
    private var watchedLast: Set<NetworkAlert> = []

    /// The public address is a network request, so it is asked for far less
    /// often than the tick and only while something is watching it.
    private var ticks = 0

    func check(link: NetworkMonitor.Link, details: NetworkInfo.Details) {
        let watched = Set(NetworkAlert.allCases.filter { $0.isWatched })
        // A watch switched off forgets what it saw, so switching it back on
        // does not immediately report a change that happened while nobody
        // was looking.
        for alert in watchedLast.subtracting(watched) { reset(alert) }
        watchedLast = watched
        ticks += 1

        if watched.contains(.connection),
           let change = connection.check(link.isReachable) {
            post(.connection, change.to ? localized("Internet connection established")
                                        : localized("Internet connection lost"))
        }
        if watched.contains(.interface),
           let change = interface.check(link.interface ?? details.primaryInterface ?? "—") {
            post(.interface, "\(change.from) → \(change.to)")
        }
        if watched.contains(.localIP),
           let change = localIP.check(details.localIP ?? "—") {
            post(.localIP, "\(change.from) → \(change.to)")
        }
        if watched.contains(.wifi),
           let change = wifi.check(details.ssid ?? "—") {
            post(.wifi, "\(change.from) → \(change.to)")
        }

        // Every two minutes, and only while watched and permitted. The module
        // this replaces asked on a timer whether anybody cared.
        if watched.contains(.publicIP), NetworkSettings.looksUpPublicIP, ticks % 120 == 1 {
            NetworkInfo.lookUpPublicIP { [weak self] address in
                guard let self, let address else { return }
                if let change = self.publicIP.check(address) {
                    self.post(.publicIP, "\(change.from) → \(change.to)")
                }
            }
        }
    }

    func withdrawAll() {
        NetworkAlert.allCases.forEach { ThresholdNotice.withdraw($0.notificationID) }
        NetworkAlert.allCases.forEach { reset($0) }
        watchedLast.removeAll()
    }

    private func reset(_ alert: NetworkAlert) {
        switch alert {
        case .connection: connection.reset()
        case .interface:  interface.reset()
        case .localIP:    localIP.reset()
        case .publicIP:   publicIP.reset()
        case .wifi:       wifi.reset()
        }
    }

    private func post(_ alert: NetworkAlert, _ detail: String) {
        ThresholdNotice.show(id: alert.notificationID,
                             title: localized("Network"),
                             detail: detail)
    }
}

/// The network page in Settings.
final class NetworkSettingsPage: NSView {

    private var shown: Set<MenuBarStyle>
    private let styles = NetworkModule().menuBarStyles

    init() {
        self.shown = Set(MenuBarStyles.stored(for: "Network",
                                              default: NetworkModule().defaultMenuBarStyles))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        let section = Controls.section(localized("Network"), symbol: "network", tint: .systemTeal, [
            Controls.row(localized("Keyboard shortcut"), ShortcutRecorder(module: "Network")),
            Controls.row(localized("Top processes"), Controls.choice(
                [("None", "0"), ("5", "5"), ("8", "8")],
                selected: "\(NetworkSettings.processCount)") { value in
                    NetworkSettings.processCount = Int(value) ?? 8
                }),
            Controls.row(localized("Look up the public address"),
                         Controls.toggle(NetworkSettings.looksUpPublicIP) { on in
                             NetworkSettings.looksUpPublicIP = on
                         },
                         detail: localized(
                            "Asks ifconfig.co, an outside server, while the popup is open: on opening, every two minutes, and when the connection changes."))
        ])

        let shapes = Controls.section(
            localized("Menu bar"), symbol: "menubar.rectangle", tint: .systemBlue,
            footer: localized("Pick one or more. They sit side by side in the menu bar, in this order."),
            [Controls.shapes(self.styles, shown: self.shown, label: "NET",
                             value: "1.2 MB/s", ) { chosen in
                self.shown = chosen
                // In the order the tiles are laid out, not the order they
                // were clicked, so the menu bar matches the page.
                MenuBarStyles.store(self.styles.filter(chosen.contains), for: "Network")
            }])

        let alerts = Controls.section(localized("Notify me when"), symbol: "bell.badge.fill",
                                      tint: .systemRed,
            NetworkAlert.allCases.map { alert in
                Controls.row(alert.title, Controls.toggle(alert.isWatched) { on in
                    alert.isWatched = on
                })
            })

        let column = NSStackView(views: [section, shapes, alerts])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 44, left: 18, bottom: 18, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            section.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            shapes.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            alerts.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
