import Foundation

/// A report somebody can paste into an issue.
///
/// Roost reads hardware, and the way it fails on a Mac nobody here owns is a
/// reading that quietly goes missing. `Tools/hardware-report.swift` answers
/// that for a developer with a checkout; this answers it for everybody else,
/// from a button in Settings.
///
/// **Everything identifying is left out, by construction.** This text is
/// going into a public issue, and a diagnostics feature that leaks a serial
/// number or a home Wi-Fi name has done more harm than the bug it was
/// helping with. So the rule here is not "redact what looks sensitive" --
/// which is a judgement made freshly, and wrongly, each time something is
/// added -- it is that identifying values never enter the report at all. The
/// report says *whether* a reading answered and *how many* of a thing there
/// were, never which one.
enum Diagnostics {

    /// What the report is built from. A value rather than live calls, so the
    /// redaction can be tested by feeding it things that must not come out
    /// the other end.
    struct Input {
        var appVersion = ""
        var build = ""
        var macOS = ""
        var modelIdentifier = ""
        var chip: String?
        var physicalCores: Int?
        /// Name and core count per performance level, kernel's own names.
        var perfLevels: [(name: String, cores: Int)] = []
        var memoryBytes: Int64 = 0
        var gpuName: String?

        var smcAvailable = false
        var smcKeyCount: Int?
        var sensorCount: Int?
        var hidSensorCount: Int?
        var fanCount: Int?

        var gpuUtilization: Double?
        var gpuRenderer: Double?
        var gpuMemoryUsed: UInt64?

        var volumeCount: Int?
        var blockDeviceCount: Int?

        var hasPrimaryInterface = false
        var isWiFi = false
        var hasPublicAddressLookup = false

        /// One line per module, from `MonitorBar.moduleReport`: on or off,
        /// whether the hardware offers it, and what became of its item. The
        /// one way to see why a module is missing from somebody's menu bar.
        var menuBar: [String] = []

        // Deliberately absent from the report, and present here only so the
        // tests can prove they do not reach it: serial number, SSID, local
        // and public IP, MAC address, router address, DNS servers, volume
        // names, user name, host name. None of them tells anybody anything
        // about a reader that a count does not.
        var serialNumber: String?
        var ssid: String?
        var localIP: String?
        var macAddress: String?
        var volumeNames: [String] = []
    }

    static func report(_ input: Input) -> String {
        var out: [String] = []

        func line(_ label: String, _ value: String?) {
            out.append("  \(label.padding(toLength: max(26, label.count), withPad: " ", startingAt: 0)) \(value ?? "—")")
        }
        func count(_ label: String, _ value: Int?) {
            line(label, value.map(String.init))
        }

        out.append("Roost \(input.appVersion) (\(input.build)) · macOS \(input.macOS)")
        out.append("")
        out.append("Machine")
        line("model identifier", input.modelIdentifier)
        line("chip", input.chip)
        count("physical cores", input.physicalCores)
        for level in input.perfLevels {
            line("  \(level.name) cores", String(level.cores))
        }
        line("memory", input.memoryBytes > 0
             ? "\(input.memoryBytes / 1_073_741_824) GB" : nil)
        line("GPU", input.gpuName)

        out.append("")
        out.append("Readings")
        line("AppleSMC", input.smcAvailable ? "reachable" : nil)
        count("SMC keys", input.smcKeyCount)
        count("sensors", input.sensorCount)
        count("HID temperature sensors", input.hidSensorCount)
        count("fans", input.fanCount)
        line("GPU utilization", input.gpuUtilization.map { String(format: "%.0f%%", $0) })
        line("GPU renderer", input.gpuRenderer.map { String(format: "%.0f%%", $0) })
        line("GPU memory in use", input.gpuMemoryUsed.map { "\($0 / 1_048_576) MB" })
        count("volumes", input.volumeCount)
        count("block devices", input.blockDeviceCount)
        line("primary interface", input.hasPrimaryInterface ? "present" : nil)
        line("Wi-Fi", input.isWiFi ? "yes" : "no")
        line("public address lookup", input.hasPublicAddressLookup ? "on" : "off")

        if !input.menuBar.isEmpty {
            out.append("")
            out.append("Menu bar")
            for module in input.menuBar { out.append("  \(module)") }
        }

        out.append("")
        out.append("A dash means this Mac did not answer. That is not always a")
        out.append("fault -- a fanless Mac has no fan speed. It is worth")
        out.append("reporting when it is something your Mac plainly has.")
        out.append("")
        out.append("No serial number, network name or address is included.")

        return out.joined(separator: "\n")
    }
}
