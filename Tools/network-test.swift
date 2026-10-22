//
//  network-test.swift
//
//  Exercises the Network module's maths and formatting.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Monitor/Readings.swift \
//            Roost/Monitor/NetworkInfo.swift \
//            Roost/Monitor/NetworkMonitor.swift \
//            Tools/network-test.swift | swift -
//
//  Rates are the part of this module that can be wrong quietly. A counter
//  that went backwards, a clock that did not move, a machine that slept --
//  none of these produce an error, they produce a plausible wrong number. A
//  live network card will not reproduce them to order, so the arithmetic is
//  tested directly and the live reader is checked only for the invariants
//  that must hold on any machine.
//
import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

typealias Counters = NetworkMonitor.Counters

// MARK: - Rate arithmetic

print("NetworkMonitor.rate")

do {
    let rate = NetworkMonitor.rate(from: Counters(received: 1_000, sent: 500),
                                   to: Counters(received: 3_000, sent: 1_500),
                                   elapsed: 2)
    check("bytes per second over the interval",
          rate?.download == 1_000 && rate?.upload == 500)
}

do {
    // Half a second of traffic is still a rate per second.
    let rate = NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                                   to: Counters(received: 512, sent: 256),
                                   elapsed: 0.5)
    check("a sub-second interval scales up",
          rate?.download == 1_024 && rate?.upload == 512)
}

do {
    check("no traffic is a rate of zero, not nil",
          NetworkMonitor.rate(from: Counters(received: 10, sent: 10),
                              to: Counters(received: 10, sent: 10),
                              elapsed: 1)?.download == 0)
}

// MARK: - The refusals

print("\nNetworkMonitor.rate refusals")

do {
    check("a zero interval is refused",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                              to: Counters(received: 100, sent: 100),
                              elapsed: 0) == nil)
    check("a negative interval is refused",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                              to: Counters(received: 100, sent: 100),
                              elapsed: -1) == nil)
    check("a non-finite interval is refused",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                              to: Counters(received: 100, sent: 100),
                              elapsed: .infinity) == nil)
}

do {
    // Waking from sleep: the bytes are real, but averaging them over the nap
    // would report a trickle that never happened.
    check("a gap longer than a minute is refused",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                              to: Counters(received: 1_000_000, sent: 1_000_000),
                              elapsed: 3_600) == nil)
    check("just under a minute is still measured",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                              to: Counters(received: 590, sent: 59),
                              elapsed: 59) != nil)
}

do {
    // An interface reset, or the primary interface changing underneath us.
    check("a download counter that went backwards is refused",
          NetworkMonitor.rate(from: Counters(received: 5_000, sent: 0),
                              to: Counters(received: 10, sent: 10),
                              elapsed: 1) == nil)
    check("an upload counter that went backwards is refused",
          NetworkMonitor.rate(from: Counters(received: 0, sent: 5_000),
                              to: Counters(received: 10, sent: 10),
                              elapsed: 1) == nil)
}

// MARK: - The 32-bit wrap

print("\nNetworkMonitor.advance")

do {
    // `ifi_ibytes` is a u_int32_t: every 4 GiB it starts again from zero.
    // Taken for a reset, it zeroed "since launch" after each big download.
    let top: UInt64 = UInt64(UInt32.max)
    check("a counter that moved forward moved that far",
          NetworkMonitor.advance(from: 100, to: 350) == 250)
    check("a counter that wrapped moved round the top",
          NetworkMonitor.advance(from: top - 99, to: 400) == 500)
    check("a rate across the wrap is measured, not dropped",
          NetworkMonitor.rate(from: Counters(received: top - 999, sent: 0),
                              to: Counters(received: 1_000, sent: 0),
                              elapsed: 1)?.download == 2_000)
    check("a small step backwards is a reset, not 4 GiB of traffic",
          NetworkMonitor.advance(from: 5_000, to: 10) == nil)
    check("a 64-bit counter going backwards is a reset",
          NetworkMonitor.advance(from: top + 10, to: 5) == nil)
}

do {
    // Nothing that reaches a chart may be NaN or infinite: AppKit draws a
    // path through it and the view breaks rather than looking wrong.
    let rate = NetworkMonitor.rate(from: Counters(received: 0, sent: 0),
                                   to: Counters(received: .max / 2, sent: .max / 2),
                                   elapsed: 0.001)
    check("even an absurd delta stays finite",
          (rate?.download ?? .nan).isFinite && (rate?.upload ?? .nan).isFinite)
}

// MARK: - Interface filter

print("\nNetworkMonitor.isPhysical")

do {
    check("ethernet and wifi count", NetworkMonitor.isPhysical("en0"))
    check("loopback does not", !NetworkMonitor.isPhysical("lo0"))
    check("tunnels do not", !NetworkMonitor.isPhysical("utun3"))
    check("AWDL does not", !NetworkMonitor.isPhysical("awdl0"))
    check("low-latency WLAN does not", !NetworkMonitor.isPhysical("llw0"))
    check("bridges do not", !NetworkMonitor.isPhysical("bridge100"))
    check("the access-point interface does not", !NetworkMonitor.isPhysical("ap1"))
}

// MARK: - Formatting

print("\nRate formatting")

do {
    // Bytes per second throughout -- never bits. A reading that silently
    // switched units would read eight times too fast.
    check("bytes stay bytes", Readings.rate(512) == "512 B/s")
    // One decimal below 100, none at or above it -- so the width of the
    // reading stays roughly constant as the rate climbs, which is what keeps
    // the menu bar item from resizing every second.
    check("a kilobyte is 1024 bytes", Readings.rate(1_024) == "1.0 KB/s")
    check("under 100 keeps a decimal", Readings.rate(1_536) == "1.5 KB/s")
    check("at 100 the decimal is dropped", Readings.rate(102_400) == "100 KB/s")
    check("megabytes round to one place", Readings.rate(1_572_864) == "1.5 MB/s")
    check("zero reads as zero", Readings.rate(0) == "0 B/s")
    check("a negative rate cannot be printed", Readings.rate(-5) == "0 B/s")
}

// MARK: - Popup status line

print("\nNetworkInfo.health")

do {
    typealias H = NetworkInfo.Health
    check("a link that is down is offline whatever the probe said",
          NetworkInfo.health(isUp: false, isReachable: true, probed: true) == H.offline)
    // isReachable starts false, so reading it before any probe returned
    // would greet every launch with "No internet".
    check("up but never probed is checking, not no internet",
          NetworkInfo.health(isUp: true, isReachable: false, probed: false) == H.checking)
    check("up and answered is online",
          NetworkInfo.health(isUp: true, isReachable: true, probed: true) == H.online)
    check("up and unanswered is no internet",
          NetworkInfo.health(isUp: true, isReachable: false, probed: true) == H.noInternet)
}

print("\nNetworkInfo.signalLevel")

do {
    // Each band boundary, from both sides: the glyph and the word beside it
    // must change at the same dBm.
    let cases: [(Int, String)] = [(-40, "excellent"), (-50, "excellent"), (-51, "good"),
                                  (-60, "good"), (-61, "fair"), (-70, "fair"),
                                  (-71, "weak"), (-90, "weak")]
    var levels: [Double] = []
    for (rssi, word) in cases {
        check("\(rssi) dBm is \(word)", NetworkInfo.signalQuality(rssi) == word)
        levels.append(NetworkInfo.signalLevel(rssi))
    }
    check("the glyph never fills as the signal weakens",
          zip(levels, levels.dropFirst()).allSatisfy { $0 >= $1 })
    check("a weak signal still draws something", NetworkInfo.signalLevel(-95) > 0)
    check("four words, four distinct levels",
          Set([-45, -55, -65, -80].map(NetworkInfo.signalLevel)).count == 4)
}

// MARK: - The live reader

print("\nNetworkMonitor live")

do {
    let monitor = NetworkMonitor.shared
    monitor.resetSessionTotals()
    monitor.sample()
    check("the first sample reports no traffic yet",
          monitor.sessionDownload == 0 && monitor.sessionUpload == 0)

    Thread.sleep(forTimeInterval: 1.1)
    monitor.sample()

    check("rates are finite", monitor.rates.download.isFinite && monitor.rates.upload.isFinite)
    check("rates are not negative", monitor.rates.download >= 0 && monitor.rates.upload >= 0)
    check("history grew", !monitor.downloadHistory.isEmpty)
    check("history holds only finite values",
          monitor.downloadHistory.allSatisfy { $0.isFinite }
            && monitor.uploadHistory.allSatisfy { $0.isFinite })
    check("an interface was chosen", monitor.link.interface != nil)
}

do {
    // The charts read the whole array every draw, so it must never grow
    // without bound no matter how long the app has been up.
    let monitor = NetworkMonitor.shared
    for _ in 0..<250 { monitor.sample() }
    check("download history stays bounded", monitor.downloadHistory.count <= 180)
    check("upload history stays bounded", monitor.uploadHistory.count <= 180)
}

print("\nPublic address")

check("an IPv4 address is an address", NetworkInfo.parsePublicIP("122.152.54.39\n") == "122.152.54.39")
check("an IPv6 address is an address", NetworkInfo.parsePublicIP("2001:db8::1") == "2001:db8::1")
check("a captive portal's page is not", NetworkInfo.parsePublicIP("<html><body>Sign in to Wi-Fi</body></html>") == nil)
check("nor is an empty reply", NetworkInfo.parsePublicIP("  \n") == nil)
check("nor a number that only looks like one", NetworkInfo.parsePublicIP("999.1.1.1") == nil)
// The reply ifconfig.co/json gave on this Mac, trimmed to what is read.
let reply = Data(#"{"ip":"122.152.54.39","country":"Bangladesh","country_iso":"BD","asn_org":"Innovative Online Limited"}"#.utf8)
let parsed = NetworkInfo.parsePublicAddress(reply)
check("the JSON reply gives the address", parsed?.ip == "122.152.54.39")
check("and the country", parsed?.countryCode == "BD" && parsed?.countryName == "Bangladesh")
check("and the network", parsed?.network == "Innovative Online Limited")
check("BD is the Bangladeshi flag", NetworkInfo.flag("BD") == "\u{1F1E7}\u{1F1E9}")
check("lower case works the same", NetworkInfo.flag("bd") == NetworkInfo.flag("BD"))
check("a code that is not two letters draws no flag", NetworkInfo.flag("B1") == nil && NetworkInfo.flag("BGD") == nil)
check("a reply with no real address is no reading",
      NetworkInfo.parsePublicAddress(Data(#"{"ip":"<html>","country_iso":"BD"}"#.utf8)) == nil)
check("a missing or odd country still gives the address, without a flag",
      NetworkInfo.parsePublicAddress(Data(#"{"ip":"1.2.3.4","country_iso":"XYZ"}"#.utf8))?.countryCode == nil)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
