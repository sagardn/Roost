import Foundation
import Darwin

/// The network module's data layer: per-interface throughput, session totals,
/// link and internet status, latency, jitter, and the history behind the
/// charts.
///
/// `Readings.network()` sums every real interface into one rate, which is all
/// the menu bar needs. The popup needs more than that -- which interface, how
/// much this session, is the link up, is the internet up, how far away is it
/// -- so the counters are kept per interface here instead.
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    // MARK: - What the popup reads

    struct Rates {
        var download: Double = 0        // bytes/second
        var upload: Double = 0
    }

    struct Link {
        var interface: String?          // "en0"
        var isUp = false                // the link itself
        var isReachable = false         // something answered on the far side
    }

    /// Bytes/second on the primary interface, as of the last sample.
    private(set) var rates = Rates()
    /// Bytes carried since the app launched, primary interface only.
    private(set) var sessionDownload: UInt64 = 0
    private(set) var sessionUpload: UInt64 = 0
    private(set) var link = Link()
    /// Round-trip time to the probe host, in milliseconds.
    private(set) var latency: Double?
    /// Mean absolute difference between consecutive round trips, milliseconds.
    private(set) var jitter: Double?

    /// Newest last. Drawn as the two mirrored lines in the popup.
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []
    /// Newest last. One entry per probe -- the grid of squares.
    private(set) var connectivityHistory: [Bool] = []

    /// How much history to keep. 180 samples is 3 minutes at one per second.
    private let historyLimit = 180
    private let connectivityLimit = 120
    /// Round trips kept for the jitter calculation.
    private let latencyWindow = 12

    // MARK: - Probe target

    /// Where the reachability and latency probes go. A plain TCP handshake to
    /// a well-known resolver rather than ICMP: an unprivileged ping needs a
    /// datagram ICMP socket and hand-rolled checksums, and the handshake is
    /// both simpler and a truer measure of what a connection will feel like.
    var probeHost = "1.1.1.1"
    var probePort: UInt16 = 53

    // MARK: - State

    private var lastCounters: [String: Counters] = [:]
    /// Where each interface's counters stood when Roost first saw it.
    private var baselines: [String: Counters] = [:]
    private var lastSampledAt = Date.distantPast
    private var recentLatencies: [Double] = []
    private var probing = false
    private let probeQueue = DispatchQueue(label: "com.sagar.roost.network.probe",
                                           qos: .utility)

    /// Internal rather than private so the rate maths can be tested.
    struct Counters { var received: UInt64 = 0; var sent: UInt64 = 0 }

    private init() {}

    // MARK: - Sampling

    /// Call once per tick from whatever timer is already running. Cheap: one
    /// getifaddrs walk. The probe is separate and runs far less often.
    func sample() {
        let now = Date()
        let counters = interfaceCounters()
        let primary = primaryInterface(from: counters)

        link.interface = primary
        link.isUp = primary.map { upInterfaces.contains($0) } ?? false

        defer { lastCounters = counters; lastSampledAt = now }

        guard let primary, let current = counters[primary] else { return }

        // Session totals come from the absolute counter against a baseline,
        // not from summing the per-tick deltas. Sampling only runs while the
        // popup is open, so a sum would have reported the few megabytes moved
        // while you were looking at it rather than everything since launch.
        // A counter below its baseline means the interface was reset, so the
        // baseline moves with it.
        if let base = baselines[primary],
           current.received >= base.received, current.sent >= base.sent {
            sessionDownload = current.received - base.received
            sessionUpload = current.sent - base.sent
        } else {
            baselines[primary] = current
            sessionDownload = 0
            sessionUpload = 0
        }

        guard let previous = lastCounters[primary] else { return }

        guard let measured = Self.rate(from: previous, to: current,
                                       elapsed: now.timeIntervalSince(lastSampledAt))
        else { return }

        rates = measured
        append(&downloadHistory, rates.download, limit: historyLimit)
        append(&uploadHistory, rates.upload, limit: historyLimit)
    }

    /// Bytes per second between two counter readings, or nil where no honest
    /// rate can be had.
    ///
    /// Pulled out of `sample()` so it can be exercised without a network
    /// card: every refusal below is a real condition this has to survive, and
    /// a live interface will not produce them to order. See
    /// Tools/network-test.swift.
    ///
    /// nil rather than zero, deliberately -- zero is a reading that says the
    /// link was idle, and none of these cases know that.
    static func rate(from previous: Counters, to current: Counters,
                     elapsed: TimeInterval) -> Rates? {
        // A clock that did not move, or moved backwards, divides by nothing.
        guard elapsed > 0, elapsed.isFinite else { return nil }
        // A gap this long means the machine slept; the bytes are real but
        // averaging them over the sleep would report a trickle that never
        // happened.
        guard elapsed < 60 else { return nil }
        // Counters below their predecessor mean the interface was reset or
        // swapped underneath us, so there is nothing to subtract from.
        guard current.received >= previous.received,
              current.sent >= previous.sent else { return nil }

        return Rates(download: Double(current.received - previous.received) / elapsed,
                     upload: Double(current.sent - previous.sent) / elapsed)
    }

    /// The reachability and latency probe. Networked, so it is deliberately
    /// not on the sampling tick -- call it every few seconds at most.
    func probe() {
        guard !probing else { return }
        probing = true
        probeQueue.async { [self] in
            let milliseconds = Self.handshake(host: probeHost, port: probePort, timeout: 2)
            DispatchQueue.main.async { [self] in
                probing = false
                link.isReachable = milliseconds != nil
                append(&connectivityHistory, milliseconds != nil, limit: connectivityLimit)

                guard let milliseconds else { return }
                latency = milliseconds
                recentLatencies.append(milliseconds)
                if recentLatencies.count > latencyWindow { recentLatencies.removeFirst() }
                jitter = Self.jitter(of: recentLatencies)
            }
        }
    }

    /// Peak of each line, which the chart prints in its corners.
    var peaks: (download: Double, upload: Double) {
        (downloadHistory.max() ?? 0, uploadHistory.max() ?? 0)
    }

    func resetSessionTotals() {
        baselines.removeAll()
        sessionDownload = 0
        sessionUpload = 0
    }

    // MARK: - Interface counters

    /// Interfaces that were up and running at the last walk.
    private var upInterfaces: Set<String> = []

    private func interfaceCounters() -> [String: Counters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return [:] }
        defer { freeifaddrs(head) }

        var counters: [String: Counters] = [:]
        var up: Set<String> = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = start

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard Self.isPhysical(name),
                  current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            if flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 { up.insert(name) }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = Counters(received: UInt64(stats.ifi_ibytes),
                                      sent: UInt64(stats.ifi_obytes))
        }
        upInterfaces = up
        return counters
    }

    /// Loopback, tunnels, AWDL, low-latency WLAN and bridges are not traffic
    /// anyone means when they say "my network".
    /// Internal rather than private so the interface filter can be tested.
    static func isPhysical(_ name: String) -> Bool {
        for prefix in ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "ap"]
        where name.hasPrefix(prefix) { return false }
        return true
    }

    private var cachedPrimary: String?
    private var cachedPrimaryAt = Date.distantPast

    /// Whatever the system calls primary, falling back to the busiest link so
    /// the popup still reads something on an unusual setup.
    ///
    /// Cached for five seconds. NetworkInfo.current() opens an
    /// SCDynamicStore and asks CoreWLAN for the SSID, which is far too much
    /// to do on a once-a-second sampling tick -- and the primary interface
    /// changes when you join a network, not every second.
    private func primaryInterface(from counters: [String: Counters]) -> String? {
        if Date().timeIntervalSince(cachedPrimaryAt) > 5 {
            cachedPrimary = NetworkInfo.current().primaryInterface
            cachedPrimaryAt = Date()
        }
        if let primary = cachedPrimary, counters[primary] != nil {
            return primary
        }
        return counters.max { lhs, rhs in
            (lhs.value.received + lhs.value.sent) < (rhs.value.received + rhs.value.sent)
        }?.key
    }

    // MARK: - Probing

    /// Milliseconds to complete a TCP handshake, or nil if it did not.
    private static func handshake(host: String, port: UInt16, timeout: TimeInterval) -> Double? {
        var hints = addrinfo(ai_flags: 0,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else {
            return nil
        }
        defer { freeaddrinfo(info) }

        let descriptor = socket(resolved.pointee.ai_family,
                                resolved.pointee.ai_socktype,
                                resolved.pointee.ai_protocol)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }

        let started = DispatchTime.now()

        if Darwin.connect(descriptor, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 {
            return elapsedMilliseconds(since: started)
        }
        guard errno == EINPROGRESS else { return nil }

        var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptors, 1, Int32(timeout * 1000)) > 0 else { return nil }

        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0,
              failure == 0 else { return nil }

        return elapsedMilliseconds(since: started)
    }

    private static func elapsedMilliseconds(since started: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    }

    /// Mean absolute difference between consecutive round trips. The same
    /// shape as RFC 3550's interarrival jitter without the smoothing, which
    /// would make a figure meant to be read live lag behind the link.
    private static func jitter(of samples: [Double]) -> Double? {
        guard samples.count >= 2 else { return nil }
        var total: Double = 0
        for index in 1..<samples.count {
            total += abs(samples[index] - samples[index - 1])
        }
        return total / Double(samples.count - 1)
    }

    private func append<T>(_ history: inout [T], _ value: T, limit: Int) {
        history.append(value)
        if history.count > limit { history.removeFirst(history.count - limit) }
    }
}
