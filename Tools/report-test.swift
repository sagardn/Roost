//
//  report-test.swift
//
//  Exercises the diagnostics report, and mostly what it must never contain.
//
//  Run:  cat Roost/System/SystemReport.swift Tools/report-test.swift | swift -
//
//  The report exists to be pasted into a public issue. Everything else about
//  it is a convenience; this is the part that can do harm. So the sensitive
//  fields are set to sentinels here and the whole text is searched for them,
//  rather than trusting that `report` was written carefully -- it is the next
//  edit that worries me, not this one.
//
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// Every identifying field filled with something unmistakable.
func loaded() -> Diagnostics.Input {
    var i = Diagnostics.Input()
    i.appVersion = "1.0.15"
    i.build = "842"
    i.macOS = "26.0"
    i.modelIdentifier = "Mac14,2"
    i.chip = "Apple M2"
    i.physicalCores = 8
    i.perfLevels = [("Efficiency", 4), ("Performance", 4)]
    i.memoryBytes = 17_179_869_184
    i.gpuName = "Apple M2 (8 cores)"
    i.smcAvailable = true
    i.smcKeyCount = 1762
    i.sensorCount = 229
    i.hidSensorCount = 38
    i.volumeCount = 2
    i.blockDeviceCount = 2
    i.hasPrimaryInterface = true
    i.isWiFi = true

    i.serialNumber = "SENTINELSERIAL123"
    i.ssid = "SENTINEL-HOME-WIFI"
    i.localIP = "198.51.100.77"
    i.macAddress = "ab:cd:ef:00:11:22"
    i.volumeNames = ["SENTINEL-Macintosh-HD", "SENTINEL-Backup-Drive"]
    return i
}

// MARK: - What must never appear

print("Diagnostics.report redaction")

let text = Diagnostics.report(loaded())

check("the serial number is not in it", !text.contains("SENTINELSERIAL123"))
check("the Wi-Fi name is not in it", !text.contains("SENTINEL-HOME-WIFI"))
check("the local address is not in it", !text.contains("198.51.100.77"))
check("the MAC address is not in it", !text.contains("ab:cd:ef:00:11:22"))
check("no volume name is in it",
      !text.contains("SENTINEL-Macintosh-HD") && !text.contains("SENTINEL-Backup-Drive"))
// The blunt version of the same: nothing recognisable, however it was spelled.
check("nothing marked as a sentinel reaches the text",
      !text.uppercased().contains("SENTINEL"))
check("and it says so, so a reader knows what they are pasting",
      text.contains("No serial number, network name or address"))

// MARK: - What must appear

print("\nWhat it does say")

check("the app version", text.contains("1.0.15"))
check("the build", text.contains("842"))
check("the model identifier", text.contains("Mac14,2"))
check("the chip", text.contains("Apple M2"))
check("the kernel's own names for the clusters",
      text.contains("Efficiency") && text.contains("Performance"))
check("memory in whole gigabytes", text.contains("16 GB"))
check("the SMC key count", text.contains("1762"))
check("the sensor count", text.contains("229"))
// Counts, never identities: two volumes, not which two.
check("how many volumes, not which", text.contains("volumes") && text.contains("2"))

print("\nThe menu bar")
do {
    var i = loaded()
    i.menuBar = ["Disk:on:available:visible+38:hidden", "Sensors:on:available:visible+34:covered"]
    let text = Diagnostics.report(i)
    check("each module's line is in it",
          text.contains("Disk:on:available:visible+38:hidden")
          && text.contains("Sensors:on:available:visible+34:covered"))
    check("under its own heading", text.contains("\nMenu bar\n"))
    check("and the heading is left out when there is nothing to list",
          !Diagnostics.report(loaded()).contains("\nMenu bar\n"))
}

// MARK: - A Mac that answers nothing

print("\nA machine with no sensors")

do {
    var bare = Diagnostics.Input()
    bare.appVersion = "1.0.15"
    bare.build = "842"
    bare.macOS = "26.0"
    bare.modelIdentifier = "VirtualMac2,1"
    let text = Diagnostics.report(bare)

    check("a missing reading is a dash, never a zero", text.contains("—"))
    check("and never reports a sensor count of 0", !text.contains("sensors                    0"))
    check("the report is still produced", text.contains("VirtualMac2,1"))
    check("and still explains what a dash means",
          text.contains("did not answer"))
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
