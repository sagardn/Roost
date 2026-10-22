import Foundation
import SystemConfiguration
import CoreWLAN
import Darwin

/// Connection details for the network submenu.
enum NetworkInfo {

    struct Details {
        var primaryInterface: String?
        var router: String?
        var dns: [String] = []
        var localIP: String?
        var wifiInterface: String?
        var ssid: String?
        var ssidBlocked = false      // nil because of permission, not absence
        var rssi: Int?
        var txRate: Double?
        var channel: Int?
        var macAddress: String?
    }

    static func current() -> Details {
        var details = Details()

        if let store = SCDynamicStoreCreate(nil, "roost" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                        as? [String: Any] {
            details.primaryInterface = global["PrimaryInterface"] as? String
            details.router = global["Router"] as? String
            if let service = global["PrimaryService"] as? String,
               let dns = SCDynamicStoreCopyValue(
                    store, "State:/Network/Service/\(service)/DNS" as CFString) as? [String: Any],
               let servers = dns["ServerAddresses"] as? [String] {
                details.dns = servers
            }
        }

        details.localIP = ipv4(for: details.primaryInterface ?? "en0") ?? ipv4(for: "en0")

        // Wi-Fi radio details. ssid() returns nil without Location permission
        // on macOS 14+, which is indistinguishable from "not on Wi-Fi" unless
        // we check whether the radio is actually up.
        if let wifi = CWWiFiClient.shared().interface() {
            details.wifiInterface = wifi.interfaceName
            details.macAddress = wifi.hardwareAddress()
            details.rssi = wifi.rssiValue() == 0 ? nil : wifi.rssiValue()
            details.txRate = wifi.transmitRate() == 0 ? nil : wifi.transmitRate()
            details.channel = wifi.wlanChannel()?.channelNumber
            details.ssid = wifi.ssid()
            details.ssidBlocked = (details.ssid == nil && wifi.powerOn())
        }
        return details
    }

    /// Signal strength in words; dBm alone means little to most people.
    static func signalQuality(_ rssi: Int) -> String {
        switch rssi {
        case (-50)...:    return "excellent"
        case (-60)..<(-50): return "good"
        case (-70)..<(-60): return "fair"
        default:          return "weak"
        }
    }

    /// How full to draw the Wi-Fi glyph's arcs, for `NSImage(systemSymbolName:
    /// variableValue:)`. Steps rather than a continuous ramp so the glyph
    /// agrees with `signalQuality`: the symbol has three arcs, and a reading
    /// called "fair" must never draw the same as one called "good".
    static func signalLevel(_ rssi: Int) -> Double {
        switch signalQuality(rssi) {
        case "excellent": return 1
        case "good":      return 0.67
        case "fair":      return 0.34
        default:          return 0.01   // the dot alone, never an empty glyph
        }
    }

    /// The one-word state the Network popup leads with.
    enum Health: Equatable {
        /// The link is up and no probe has answered or failed yet. Without
        /// it, the first second after launch claimed "No internet".
        case checking
        case online
        /// Up, but the probe got no answer: captive portal, dead router.
        case noInternet
        case offline
    }

    static func health(isUp: Bool, isReachable: Bool, probed: Bool) -> Health {
        guard isUp else { return .offline }
        guard probed else { return .checking }
        return isReachable ? .online : .noInternet
    }

    private static func ipv4(for interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var pointer = head
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            return String(cString: host)
        }
        return nil
    }

    // MARK: - Public IP

    /// The last answer, and when it came. Kept for two minutes rather than
    /// for ever: the first version kept the first answer for the life of the
    /// process, so an address that changed was never seen to change, and the
    /// alert for exactly that could not fire.
    private(set) static var publicIP: String?
    /// Where the server places that address, from the same reply: ISO code
    /// ("BD"), name ("Bangladesh") and the network's operator. A lookup in a
    /// geolocation database, not a measurement -- a VPN's exit is reported
    /// as wherever the VPN is, which is the point of one.
    private(set) static var publicCountryCode: String?
    private(set) static var publicCountryName: String?
    private(set) static var publicNetwork: String?
    private(set) static var publicIPAt: Date?
    static let publicIPMaxAge: TimeInterval = 110
    private static var waiting: [(String?) -> Void] = []

    /// Deliberately on demand, never automatic: finding the public IP means
    /// contacting an outside server, and that should be the user's choice
    /// rather than something the menu does quietly in the background. The
    /// popup asks only when its button is pressed; the change alert asks
    /// only while it is switched on.
    ///
    /// Main thread only. A second caller while a request is out is answered
    /// with the same reply -- it used to get no reply at all.
    static func lookUpPublicIP(completion: @escaping (String?) -> Void) {
        if let publicIP, let at = publicIPAt, Date().timeIntervalSince(at) < publicIPMaxAge {
            completion(publicIP)
            return
        }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        // echoip (github.com/mpolden/echoip): MIT, self-hostable, and not the
        // upstream endpoint this fork was cut from.
        //
        // The JSON form, not /ip: one request, the same server, and it says
        // which country the address is in as well -- which is what the flag
        // beside the address is drawn from.
        guard let url = URL(string: "https://ifconfig.co/json") else { return finish(nil) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let address = data.flatMap(parsePublicAddress)
            DispatchQueue.main.async { finish(address) }
        }.resume()
    }

    struct PublicAddress: Equatable {
        let ip: String
        let countryCode: String?
        let countryName: String?
        let network: String?
    }

    /// The JSON reply, if it carries a real address. The country code is
    /// kept only when it is two letters -- what a flag can be drawn from.
    static func parsePublicAddress(_ data: Data) -> PublicAddress? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = (object["ip"] as? String).flatMap(parsePublicIP) else { return nil }
        let code = (object["country_iso"] as? String)?.uppercased()
        let validCode = code.flatMap { $0.count == 2 && $0.allSatisfy { ("A"..."Z").contains($0) } ? $0 : nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return PublicAddress(ip: ip, countryCode: validCode, countryName: text("country"),
                             network: text("asn_org"))
    }

    /// 🇧🇩 from "BD": the two regional indicator letters every platform
    /// draws as that country's flag.
    static func flag(_ code: String?) -> String? {
        guard let code, code.count == 2 else { return nil }
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(Character(scalar)),
                  let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// Drops the cached answer, so the next ask goes to the server: the
    /// network changed, or somebody pressed refresh.
    static func forgetPublicIP() {
        publicIPAt = nil
    }

    private static func finish(_ address: PublicAddress?) {
        if let address {
            publicIP = address.ip
            publicCountryCode = address.countryCode
            publicCountryName = address.countryName
            publicNetwork = address.network
            publicIPAt = Date()
        }
        let callers = waiting
        waiting.removeAll()
        callers.forEach { $0(address?.ip) }
    }

    /// The reply if it is an address and nothing else. A captive portal
    /// answers any request with its own web page, and that page is not the
    /// Mac's address however it is trimmed.
    static func parsePublicIP(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 45 else { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 || inet_pton(AF_INET6, trimmed, &v6) == 1 { return trimmed }
        return nil
    }
}

// MARK: - What an interface is called

extension NetworkInfo {

    /// "Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN" for `en0`,
    /// `bridge0`, `en7` -- the names System Settings ▸ Network uses.
    ///
    /// The BSD name was what the tile, the status line and the dashboard
    /// showed, and "en0" is a fact about the kernel, not about the Mac in
    /// front of somebody. SystemConfiguration knows the hardware ports by
    /// the name macOS gives them; a tunnel it does not list is a VPN as far
    /// as anybody using it is concerned.
    static func displayName(ofInterface bsdName: String) -> String {
        if let known = portNames()[bsdName] { return known }
        let prefixes: [(String, String)] = [
            ("utun", localized("VPN")), ("ipsec", localized("VPN")), ("ppp", localized("VPN")),
            ("pdp_ip", localized("Cellular")), ("bridge", localized("Bridge")),
            ("en", localized("Ethernet"))
        ]
        for (prefix, name) in prefixes where bsdName.hasPrefix(prefix) { return name }
        return bsdName
    }

    /// Hardware ports change when an adapter is plugged in, which is rare
    /// next to how often a popup redraws; a minute is fresh enough.
    private static var portCache: (names: [String: String], read: Date)?

    private static func portNames() -> [String: String] {
        if let cache = portCache, Date().timeIntervalSince(cache.read) < 60 { return cache.names }
        var names: [String: String] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = name
        }
        portCache = (names, Date())
        return names
    }
}
