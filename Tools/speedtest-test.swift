//
//  speedtest-test.swift
//
//  Reads networkQuality's summary the way the speed test does.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Log.swift \
//            Roost/Launcher/SpeedTest.swift Tools/speedtest-test.swift | swift -
//
//  The tool is never run here: a test that used the user's connection for
//  twenty seconds would be a test nobody wants to run. Its output is written
//  down from the format strings in /usr/bin/networkQuality itself.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let summary = """
==== SUMMARY ====
Uplink capacity: 38.123 Mbps
Downlink capacity: 245.678 Mbps
Responsiveness: High (24.215 milliseconds | 2478 RPM)
Idle Latency: 14.791 milliseconds | 4056 RPM
"""

print("Reading it")
let result = SpeedTest.parse(summary)
check("download in bits per second", result.map { abs($0.download - 245_678_000) < 1 } ?? false)
check("upload in bits per second", result.map { abs($0.upload - 38_123_000) < 1 } ?? false)
check("Apple's own grade, not one worked out here", result?.responsiveness == "High")
check("said in one line", result.map(SpeedTest.describe) == "↓ 246 Mbps  ↑ 38 Mbps · Responsiveness: High")

let fast = SpeedTest.parse("Uplink capacity: 0.9 Gbps\nDownlink capacity: 1.2 Gbps\nResponsiveness: Medium (80 milliseconds | 750 RPM)")
check("gigabits stay gigabits", fast.map(SpeedTest.describe) == "↓ 1.2 Gbps  ↑ 900 Mbps · Responsiveness: Medium")
let slow = SpeedTest.parse("Uplink capacity: 512 Kbps\nDownlink capacity: 3.4 Mbps")
check("a slow line keeps a decimal, and no grade is invented",
      slow.map(SpeedTest.describe) == "↓ 3.4 Mbps  ↑ 0.5 Mbps")
check("a failed run is no result", SpeedTest.parse("Error: could not reach the server") == nil)
check("half a result is no result", SpeedTest.parse("Downlink capacity: 10 Mbps") == nil)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
