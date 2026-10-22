import AppKit
import Network

/// The Network popup: a one-line verdict, the rates and their history, then
/// the connection's detail and the processes using the link.
///
/// Ordered by how often each part is the reason the popup was opened. "Am I
/// online" first, as a sentence rather than two UP pills and a latency row
/// spread down the page; the hardware detail last, folded away, since a MAC
/// address is looked up once and then never again.
///
/// All of it reads from `NetworkMonitor`, `NetworkInfo` and `ProcessNetwork`,
/// which between them touch nothing but public APIs and `nettop`.
final class NetworkModule: PopupContent {

    let title = "Network"

    // Rows held so a refresh can set their text rather than rebuild the view.
    private let status = StatusLine()
    /// Shown only while there is no way out: offline, or connected with no
    /// internet behind it. Online, it would be a link to a page nobody needs.
    private let networkSettings = PopupAction(localized("Network settings…"), symbol: "network") {
        for identifier in ["x-apple.systempreferences:com.apple.Network-Settings.extension",
                           "x-apple.systempreferences:com.apple.preference.network"] {
            if let url = URL(string: identifier),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
    private let downloadReading = BigReading(caption: localized("Download"), symbol: "arrow.down",
                                             tint: .systemIndigo)
    private let uploadReading = BigReading(caption: localized("Upload"), symbol: "arrow.up",
                                           tint: .roostAmber)
    private let chart = SplitTrafficChart()
    private let peaks = PeakLegend()
    private let reachability = ValueRow(localized("Internet checks answered"))
        .explained(localized("Roost checks every few seconds that the internet answers. Each bar below is one check."))
    private let strip = ReachabilityStrip()

    private let latency = ValueRow(localized("Response time · variation"))
        .explained(localized("How long the internet takes to answer, and how much that changes from one check to the next. Lower is better for both."))
    private let signal = SignalRow()
    /// The network's name, or the button that gets permission to read it.
    /// A row of its own on Wi-Fi rather than only in the status line, where
    /// a long name was cut off and a missing one said nothing at all.
    private let wifiName = WiFiNameRow()
    /// What identifies the network the Mac is on, to notice it change and
    /// look the public address up again.
    private var networkSignature: String?
    /// Told by the system of any change to the route out -- a VPN coming up
    /// or going down included, which changes nothing on the Wi-Fi interface
    /// and so nothing in the signature above. Only while the popup is open.
    private var pathMonitor: NWPathMonitor?
    private var pathSettle: DispatchWorkItem?
    private let localIP = ValueRow(localized("Local IP"))
    /// The address the internet sees. Its own row type: it has a button,
    /// because it is only ever looked up when somebody asks.
    private let publicIP = PublicIPRow()
    private let interfaceName = ValueRow(localized("Interface"))
    // Since launch, which is what the counter measures: the baseline is
    // taken on the first sample and nothing resets it. "Total" alone did
    // not say since when.
    private let sinceLaunch = ValueRow(localized("Sent · received since launch"))

    private let processPlaceholder = ProcessPlaceholder()
    private let processRows = (0..<8).map { _ in ProcessRow() }

    private let detailsToggle = DisclosureButton(key: "Network_popupDetails")
    private let macAddress = ValueRow(localized("Physical address"))
        .explained(localized("The hardware address (MAC address). macOS may use a private one for each Wi-Fi network."))
    private let router = ValueRow(localized("Router"))
        .explained(localized("The address of the box this Mac connects through."))
    private let dns = ValueRow(localized("DNS servers"))
        .explained(localized("The servers that turn names like apple.com into addresses."))
    private let channel = ValueRow(localized("Wi-Fi channel · speed"))
        .explained(localized("The radio channel, and the speed the Mac and the router agreed on. The internet itself may be slower."))
    private var detailRows: [NSView] { [macAddress, router, dns, channel] }

    /// Ticks since the popup opened, used to throttle the two expensive jobs
    /// away from the one-second refresh.
    private var ticks = 0
    private var cachedDetails = NetworkInfo.Details()

    /// The tile, once something has asked for it.
    private var tile: NetworkTile?

    /// The link changes this module is watching, if any are switched on.
    private let alerts = NetworkAlerts()

    /// Ticks the menu bar reading has taken. Separate from `ticks`, which
    /// only moves while the popup is open -- the alerts have to keep working
    /// when it is shut, which is when a link is most likely to change.
    private var samples = 0

    // MARK: - PopupContent

    func makeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(status)
        stack.setCustomSpacing(4, after: status)
        networkSettings.isHidden = true
        stack.addArrangedSubview(networkSettings)
        stack.setCustomSpacing(12, after: networkSettings)

        // Upload first, as everywhere else: the menu bar, the chart and the
        // totals all lead with it.
        let headline = headlinePair(uploadReading, downloadReading)
        stack.addArrangedSubview(headline)
        stack.setCustomSpacing(12, after: headline)

        stack.addArrangedSubview(chart)
        stack.setCustomSpacing(4, after: chart)
        stack.addArrangedSubview(peaks)
        stack.setCustomSpacing(10, after: peaks)

        stack.addArrangedSubview(reachability)
        stack.setCustomSpacing(4, after: reachability)
        stack.addArrangedSubview(strip)
        stack.setCustomSpacing(14, after: strip)

        stack.addArrangedSubview(SectionHeader(localized("Connection")))
        for row in [latency, signal, wifiName, localIP, publicIP, interfaceName, sinceLaunch] {
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(SectionHeader(localized("Apps using the network")))
        stack.addArrangedSubview(ProcessHeader())
        stack.addArrangedSubview(processPlaceholder)
        for row in processRows {
            row.isHidden = true
            stack.addArrangedSubview(row)
        }

        detailsToggle.install(in: stack, rows: detailRows)
        // The channel row has a condition of its own -- it means nothing off
        // Wi-Fi -- which the fold showing every row would override.
        detailsToggle.onToggle = { [weak self] _ in
            guard let self else { return }
            self.refreshInterface(NetworkMonitor.shared)
        }

        return stack
    }

    func willShow() {
        ticks = 0
        cachedDetails = NetworkInfo.current()
        publicIP.prepare()
        // Granting access mid-popup shows the name at once, rather than on
        // the next five-second re-read of the link.
        watchPath()
        WiFiNameAccess.shared.checkServices()
        WiFiNameAccess.shared.onChange = { [weak self] in
            guard let self else { return }
            self.cachedDetails = NetworkInfo.current()
            self.refreshInterface(NetworkMonitor.shared)
        }
        NetworkMonitor.shared.probe()
    }

    /// A new route means a likely new public address and country -- a VPN
    /// to another country is exactly that -- so the address is asked for
    /// again. Two seconds after the change settles: the moment a tunnel comes
    /// up, the old route may still be the one a request takes.
    private func watchPath() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        var first = true
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // The first update is the path as it already is.
                if first { first = false; return }
                self.pathSettle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    NetworkInfo.forgetPublicIP()
                    self?.publicIP.refreshIfDue()
                }
                self.pathSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    func didHide() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathSettle?.cancel()
        // Otherwise a reopen would report a rate averaged over the minutes
        // the popup spent shut.
        ProcessNetwork.reset()
    }

    /// The rates, the traffic chart, and the name. Not the six that measure
    /// a share of something: a link has no percentage to be at -- the rate it
    /// is carrying is not a fraction of anything the machine can know, since
    /// nothing reports what the link could carry.
    var defaultMenuBarStyles: [MenuBarStyle] { [.rates] }
    var menuBarStyles: [MenuBarStyle] { [.label, .rates, .trafficChart] }

    /// The tile, built once.
    func makeTile() -> NetworkTile {
        if let tile { return tile }
        let made = NetworkTile()
        made.update(NetworkMonitor.shared, interface: cachedDetails.primaryInterface
                        .map(NetworkInfo.displayName(ofInterface:)))
        tile = made
        return made
    }

    func willStop() { alerts.withdrawAll() }

    func menuBarContent() -> MenuBarReading? {
        // Sampling lives here so the rates keep moving with the popup shut.
        let monitor = NetworkMonitor.shared
        monitor.sample()
        samples += 1

        // The link's own details are an SCDynamicStore read and, on Wi-Fi, a
        // CoreWLAN one. Every fifteen seconds with the popup shut is enough
        // to notice a change; the popup refreshes them faster while it is up.
        if samples % 15 == 1 { cachedDetails = NetworkInfo.current() }
        // Reachability is a probe, and only the popup asked for one: with it
        // shut, "Connection comes or goes" compared a value nothing updated
        // and never fired. Asked here while that alert is watched, at the
        // popup's own pace; `probe()` skips a call while one is in flight.
        if NetworkAlert.connection.isWatched, samples % 5 == 0 { monitor.probe() }
        alerts.check(link: monitor.link, details: cachedDetails,
                     probed: !monitor.connectivityHistory.isEmpty)

        if let tile, tile.window?.isVisible == true {
            tile.update(monitor, interface: (monitor.link.interface ?? cachedDetails.primaryInterface)
                                 .map(NetworkInfo.displayName(ofInterface:)))
        }

        return MenuBarReading(
            label: "NET",
            value: Readings.rate(monitor.rates.download),
            rates: speedTinted(monitor.rates),
            mirrored: .init(up: monitor.uploadHistory, down: monitor.downloadHistory))
    }

    /// Upload and download, brighter the faster each goes.
    private func speedTinted(_ rates: NetworkMonitor.Rates) -> MenuBarReading.Pair {
        var pair = MenuBarReading.Pair(Readings.rate(rates.upload),
                                       Readings.rate(rates.download))
        pair.speeds = .init(upload: rates.upload, download: rates.download)
        return pair
    }

    func refresh() {
        let monitor = NetworkMonitor.shared
        ticks += 1

        // Networked, so far less often than the tick.
        if ticks % 5 == 0 { monitor.probe() }
        // Spawns nettop, which costs ~0.43s of wall time and a fifth of a
        // core each run. Every four seconds, not every two.
        if ticks % 4 == 0 { refreshProcesses() }
        // SCDynamicStore and CoreWLAN are not free either.
        if ticks % 5 == 1 { cachedDetails = NetworkInfo.current() }

        downloadReading.set(bytesPerSecond: monitor.rates.download)
        uploadReading.set(bytesPerSecond: monitor.rates.upload)

        chart.upper = monitor.uploadHistory
        chart.lower = monitor.downloadHistory
        peaks.set(upper: monitor.uploadHistory.max() ?? 0,
                  lower: monitor.downloadHistory.max() ?? 0)

        let probes = monitor.connectivityHistory
        strip.results = probes
        reachability.value = probes.isEmpty
            ? "—" : "\(probes.filter { $0 }.count) of \(probes.count)"

        latency.value = monitor.latency.map { latency in
            let jitter = monitor.jitter.map { String(format: " · %.1f ms", $0) } ?? ""
            return String(format: "%.0f ms", latency) + jitter
        } ?? "—"
        sinceLaunch.value = "↑ \(Readings.bytes(monitor.sessionUpload))"
            + "   ↓ \(Readings.bytes(monitor.sessionDownload))"

        refreshInterface(monitor)
    }

    // MARK: - Sections

    private func refreshInterface(_ monitor: NetworkMonitor) {
        let details = cachedDetails
        let name = monitor.link.interface ?? details.primaryInterface ?? "—"

        let onWiFi = details.wifiInterface == name && details.rssi != nil
        signal.isHidden = !onWiFi
        wifiName.isHidden = !onWiFi
        // ssid() returns nil without Location permission, which is
        // indistinguishable from "not on Wi-Fi" unless the radio is known to
        // be up -- NetworkInfo already made that call.
        wifiName.set(ssid: details.ssid, blocked: details.ssidBlocked)

        // A different network is very likely a different public address:
        // forget the old one and ask again, so the row follows the change
        // without being pressed. The first read only records the network.
        let signature = [name, details.router, details.localIP, details.ssid]
            .map { $0 ?? "-" }.joined(separator: "|")
        if let previous = networkSignature, previous != signature {
            NetworkInfo.forgetPublicIP()
        }
        networkSignature = signature
        publicIP.refreshIfDue()

        let medium: String
        if onWiFi, let rssi = details.rssi {
            interfaceName.value = "Wi-Fi (\(name))"
            signal.set(rssi: rssi)
            // The name has a row of its own now; in the status line it was
            // the part that got cut off.
            medium = "Wi-Fi"
        } else {
            // Named as System Settings names it, with the BSD name kept in
            // brackets for whoever is matching it against `ifconfig`.
            let display = NetworkInfo.displayName(ofInterface: name)
            interfaceName.value = display == name ? name : "\(display) (\(name))"
            // Any other physical en* is a cable: NetworkMonitor only picks
            // physical interfaces, and Wi-Fi was ruled out above.
            medium = name.hasPrefix("en") ? "Ethernet" : display
        }

        let health = NetworkInfo.health(isUp: monitor.link.isUp,
                                        isReachable: monitor.link.isReachable,
                                        probed: !monitor.connectivityHistory.isEmpty)
        setStatus(health, medium: medium, latency: monitor.latency)

        macAddress.value = details.macAddress ?? "—"
        localIP.value = details.localIP ?? "—"
        router.value = details.router ?? "—"
        dns.value = details.dns.isEmpty ? "—" : details.dns.prefix(2).joined(separator: ", ")
        channel.isHidden = !onWiFi || !detailsToggle.isOpen
        channel.value = [details.channel.map { "\($0)" },
                         details.txRate.map { String(format: "%.0f Mbps", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func setStatus(_ health: NetworkInfo.Health, medium: String, latency: Double?) {
        networkSettings.isHidden = !(health == .noInternet || health == .offline)
        switch health {
        case .checking:
            status.set(localized("Checking…"), tint: .tertiaryLabelColor, details: [medium])
        case .online:
            status.set(localized("Online"), tint: .roostCalm,
                       details: [medium] + [latency.map { String(format: "%.0f ms", $0) }]
                           .compactMap { $0 })
        case .noInternet:
            status.set(localized("No internet"), tint: .roostWarning, details: [medium])
        case .offline:
            // No medium: the interface it last used is not necessarily the
            // one it will come back on.
            status.set(localized("Offline"), tint: .roostCritical, details: [])
        }
    }

    private func refreshProcesses() {
        let wanted = min(NetworkSettings.processCount, processRows.count)
        guard wanted > 0 else {
            processRows.forEach { $0.isHidden = true }
            processPlaceholder.isHidden = true
            return
        }
        ProcessNetwork.top(wanted) { [weak self] entries in
            guard let self else { return }
            self.processPlaceholder.show(rows: entries.count, empty: localized("No app is using the network right now"))
            for (index, row) in self.processRows.enumerated() {
                if index < entries.count {
                    row.set(entries[index])
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
        }
    }
}

// MARK: - Reachability strip

/// One thin bar, a slot per probe, newest at the right.
///
/// Replaces a three-row grid of squares that reserved its full height from
/// the first probe: three answers drew as three dots above a blank band. A
/// single strip sized for the whole history is the same information in a
/// sixth of the height, and an unfilled track says "not probed yet" rather
/// than leaving empty space to be read as nothing at all.
private final class ReachabilityStrip: NSView {

    var results: [Bool] = [] { didSet { needsDisplay = true } }

    /// Matches `NetworkMonitor.connectivityLimit`, so a full history fills
    /// the strip exactly.
    private let slots = 120

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        track.fill()

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let width = bounds.width / CGFloat(slots)
        let shown = results.suffix(slots)
        let start = slots - shown.count
        for (offset, ok) in shown.enumerated() {
            // A hair of overlap, so neighbouring slots of one colour join
            // into a solid run instead of a comb of antialiased seams.
            let rect = NSRect(x: CGFloat(start + offset) * width, y: 0,
                              width: width + 0.5, height: bounds.height)
            (ok ? NSColor.roostCalm : NSColor.roostCritical).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Signal row

/// The Wi-Fi glyph filled to the signal, then the word and the dBm.
private final class SignalRow: NSView {

    private let glyph = NSImageView()
    private let value = NSTextField(labelWithString: "—")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: localized("Signal"))
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false

        glyph.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        for view in [name, glyph, value] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -5),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(rssi: Int) {
        let quality = NetworkInfo.signalQuality(rssi)
        glyph.image = NSImage(systemSymbolName: "wifi",
                              variableValue: NetworkInfo.signalLevel(rssi),
                              accessibilityDescription: "\(quality) signal")
        // Only a weak signal earns a colour: it is the one reading here that
        // explains a slow connection, and tinting the good ones too would
        // make the warning just another colour on the page.
        glyph.contentTintColor = quality == "weak" ? .roostWarning : .secondaryLabelColor
        value.stringValue = "\(quality.capitalized)  \(rssi) dBm"
    }
}

// MARK: - Dashboard

/// In this file beside the sampling it reads from.
extension NetworkModule: DashboardReporting {
    func dashboardReport() -> DashboardReport? {
        // `samples` counts the ticks this module has taken; before the second
        // there is no rate, only a counter with nothing to subtract from.
        guard samples > 1 else { return nil }
        let monitor = NetworkMonitor.shared
        let interface = monitor.link.interface ?? cachedDetails.primaryInterface
        // Both lines on the download's scale or the upload's, whichever is
        // larger, so a quiet upload reads as quiet beside a busy download.
        let peak = max(monitor.downloadHistory.max() ?? 0, monitor.uploadHistory.max() ?? 0)

        // Counters the monitor keeps from the interface's own totals; reading
        // them is two integers, not a sample.
        // One row each: on one row the pair did not fit the narrowest card
        // and came out "↓ 57.0…16.0 KB".
        var facts = [DashboardReport.Fact(label: localized("Received since launch"),
                                          value: Readings.bytes(monitor.sessionDownload)),
                     DashboardReport.Fact(label: localized("Sent since launch"),
                                          value: Readings.bytes(monitor.sessionUpload))]
        if let interface {
            facts.append(.init(label: localized("Connection"), value: NetworkInfo.displayName(ofInterface: interface)))
        }
        return DashboardReport(
            value: "↓ " + Readings.rate(monitor.rates.download),
            pair: ((localized("Download"), "↓ " + Readings.rate(monitor.rates.download)),
                   (localized("Upload"), "↑ " + Readings.rate(monitor.rates.upload))),
            caption: monitor.link.isUp ? localized("Connected") : localized("Not connected"),
            severity: .calm,
            facts: facts,
            history: monitor.downloadHistory.normalised(against: peak),
            mirror: monitor.uploadHistory.normalised(against: peak),
            signal: .network(linkUp: monitor.link.isUp))
    }
}

// MARK: - Public IP

/// "Public IP": the address the internet sees, kept current while the popup
/// is open.
///
/// Looked up on its own while "Look up the public address" is on -- which is
/// a request to an outside server, ifconfig.co, and is said so beside the
/// switch in Network settings. When the popup opens, every two minutes while
/// it stays open, and at once when the Mac moves to a different network, so a
/// new address shows without being asked for. The refresh button asks now.
/// Hidden when the setting is off, and then nothing is sent.
private final class PublicIPRow: NSView {

    private let value = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var looking = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: localized("Public IP"))
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        value.isSelectable = true
        value.translatesAutoresizingMaskIntoConstraints = false

        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(lookUpNow)
        button.translatesAutoresizingMaskIntoConstraints = false

        for view in [name, value, button] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8)
        ])
        // Not prepare(): that may look the address up, and building the
        // popup is not opening it. `willShow` calls it.
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// On every open: the setting may have changed, and a cached answer may
    /// have gone stale.
    func prepare() {
        isHidden = !NetworkSettings.looksUpPublicIP
        guard !looking else { return }
        if let address = NetworkInfo.publicIP {
            show(address)
        } else {
            value.stringValue = "—"
            setButton(symbol: "arrow.clockwise", help: localized("Look it up again"))
        }
        refreshIfDue()
    }

    /// Asks again once the last answer is two minutes old -- or has been
    /// forgotten because the network changed. Cheap to call on every tick:
    /// the cache answers until then, and nothing is sent.
    func refreshIfDue() {
        guard NetworkSettings.looksUpPublicIP, !looking else { return }
        if let at = NetworkInfo.publicIPAt, Date().timeIntervalSince(at) < NetworkInfo.publicIPMaxAge,
           NetworkInfo.publicIP != nil {
            if let address = NetworkInfo.publicIP, !value.stringValue.hasSuffix(address) { show(address) }
            return
        }
        lookUp()
    }

    /// The button: now, whatever the cache says.
    @objc private func lookUpNow() {
        NetworkInfo.forgetPublicIP()
        lookUp()
    }

    private func lookUp() {
        guard !looking else { return }
        looking = true
        // The old address stays while the new one is fetched, so the row
        // does not flicker to "Looking up…" every two minutes.
        if NetworkInfo.publicIP == nil { value.stringValue = localized("Looking up…") }
        button.isEnabled = false
        NetworkInfo.lookUpPublicIP { [weak self] address in
            guard let self else { return }
            self.looking = false
            self.button.isEnabled = true
            if let address {
                self.show(address)
            } else {
                self.value.stringValue = localized("Not reached")
                self.setButton(symbol: "arrow.clockwise", help: localized("Try again"))
            }
        }
    }

    private func show(_ address: String) {
        // The flag of the country the server places the address in, from
        // the same reply; the tooltip says where it came from, because a
        // geolocation guess is not a fact about the Mac.
        let flag = NetworkInfo.flag(NetworkInfo.publicCountryCode)
        value.stringValue = [flag, address].compactMap { $0 }.joined(separator: " ")
        let place = [NetworkInfo.publicCountryName, NetworkInfo.publicNetwork].compactMap { $0 }
            .joined(separator: " · ")
        value.toolTip = place.isEmpty ? nil : localized("%0, as ifconfig.co places this address", place)
        value.setAccessibilityLabel([localized("Public IP %0", address), NetworkInfo.publicCountryName]
            .compactMap { $0 }.joined(separator: ", "))
        setButton(symbol: "arrow.clockwise", help: localized("Look it up again"))
    }

    private func setButton(symbol: String, help: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }
}

// MARK: - Wi-Fi name

/// "Wi-Fi name", and the network's name -- or, where macOS will not give it
/// without Location access, the button that asks for that.
private final class WiFiNameRow: NSView {

    private let value = NSTextField(labelWithString: "")
    private let button = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: localized("Wi-Fi name"))
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        value.isSelectable = true
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(pressed)
        button.translatesAutoresizingMaskIntoConstraints = false

        for view in [name, value, button] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(ssid: String?, blocked: Bool) {
        if let ssid {
            value.stringValue = ssid
            value.toolTip = ssid
            button.isHidden = true
            return
        }
        guard blocked else {
            value.stringValue = "—"
            button.isHidden = true
            return
        }
        value.stringValue = localized("Hidden")
        button.isHidden = false
        switch WiFiNameAccess.shared.state {
        case .servicesOff:
            value.stringValue = localized("Location is off")
            button.title = localized("Location Services…")
            button.toolTip = localized("Location Services is off for this Mac, and macOS shows no app the Wi-Fi name without it. Turn it on in System Settings, then allow Roost.")
        case .denied:
            button.title = localized("Location Services…")
            button.toolTip = localized("Roost was refused Location access. Allow it in System Settings to show the network's name.")
        default:
            button.title = localized("Allow…")
            button.toolTip = localized("macOS shows the Wi-Fi name only to apps with Location access. Roost uses it for the name and nothing else.")
        }
    }

    @objc private func pressed() {
        switch WiFiNameAccess.shared.state {
        case .denied, .servicesOff: WiFiNameAccess.openSettings()
        default:                    WiFiNameAccess.shared.request()
        }
    }
}
