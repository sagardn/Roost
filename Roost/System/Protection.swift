import Foundation

/// Whether macOS's own protections are on.
///
/// This is not a malware scanner, and nothing in Roost is. A scanner is a
/// detection engine and a signature feed that has to be updated daily to be
/// worth anything; Roost has no third-party code and makes no network calls
/// of its own, and a scanner built without both would be a confident-looking
/// list of nothing. macOS already ships one -- XProtect, which Apple updates
/// silently -- so what is useful here is saying whether it, and the
/// protections around it, are switched on and current.
///
/// Each check reads what macOS reports about itself. Four of them have no
/// public API -- SIP, Gatekeeper, FileVault and the firewall are only
/// reported by their own command-line tools -- so those tools are run, as an
/// executable and an argument list, without privileges. Measured on an M2:
/// 5 ms each, and 51 ms for `fdesetup`.
enum Protection {

    enum State: Equatable {
        case on
        case off
        /// Not changed from the default, and the default is on. Reported apart
        /// from `.on` because Roost read no setting at all; it is saying what
        /// macOS does when nobody has chosen.
        case defaultOn
        /// The tool did not answer, or answered in words this does not know.
        /// Never guessed at: a protection reported as on when it is off is
        /// the one wrong answer here that does harm.
        case unknown
    }

    enum Check: String, CaseIterable {
        case sip, gatekeeper, fileVault, firewall, securityUpdates

        var title: String {
            switch self {
            case .sip:             return localized("System Integrity Protection")
            case .gatekeeper:      return localized("Gatekeeper")
            case .fileVault:       return localized("FileVault")
            case .firewall:        return localized("Firewall")
            case .securityUpdates: return localized("Security responses")
            }
        }

        /// What it protects against, in a line.
        var purpose: String {
            switch self {
            case .sip:
                return localized("Stops anything, even with an administrator password, from changing the system's own files.")
            case .gatekeeper:
                return localized("Checks that an app comes from an identified developer and has been checked by Apple before it first opens.")
            case .fileVault:
                return localized("Encrypts the disk, so a lost or stolen Mac does not give up what is on it.")
            case .firewall:
                return localized("Refuses incoming connections to apps you have not allowed. Off by default on macOS; it matters most on shared networks.")
            case .securityUpdates:
                return localized("Lets macOS install urgent security fixes and XProtect's malware definitions without a full update.")
            }
        }

        /// How much it matters when it is off. The firewall is off by default
        /// and most Macs never need it, so an off firewall is a note, not a
        /// warning; an off SIP is a Mac with its system files unprotected.
        var isEssential: Bool { self != .firewall }
    }

    // MARK: - Reading what the tools say

    /// `csrutil status`: "System Integrity Protection status: enabled."
    ///
    /// A custom configuration prints "unknown (Custom Configuration)" and a
    /// list of what is off; that is reported as off, because some of it is.
    static func parseSIP(_ output: String) -> State {
        let text = output.lowercased()
        guard text.contains("system integrity protection status:") else { return .unknown }
        if text.contains("custom configuration") { return .off }
        if text.contains("status: enabled") { return .on }
        if text.contains("status: disabled") { return .off }
        return .unknown
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    static func parseGatekeeper(_ output: String) -> State {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .on }
        if text.contains("assessments disabled") { return .off }
        return .unknown
    }

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off.", and while
    /// it is working, "Encryption in progress" or "Decryption in progress".
    /// Encrypting counts as on -- it is on, and finishing -- and decrypting as
    /// off, which is where it is going.
    static func parseFileVault(_ output: String) -> State {
        let text = output.lowercased()
        if text.contains("decryption in progress") { return .off }
        if text.contains("encryption in progress") { return .on }
        if text.contains("filevault is on") { return .on }
        if text.contains("filevault is off") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is disabled. (State = 0)".
    /// The number is the reliable part: 1 is on, 2 is on and blocking
    /// everything, 0 is off.
    static func parseFirewall(_ output: String) -> State {
        guard let range = output.range(of: "State = ") else {
            let text = output.lowercased()
            if text.contains("firewall is enabled") { return .on }
            if text.contains("firewall is disabled") { return .off }
            return .unknown
        }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        switch Int(digits) {
        case 0?:     return .off
        case 1?, 2?: return .on
        default:     return .unknown
        }
    }

    /// Software Update's own preferences. "Install Security Responses and
    /// system files" is two keys, `ConfigDataInstall` (XProtect's
    /// definitions among them) and `CriticalUpdateInstall`. Both are absent
    /// on a Mac where nobody has touched the switch -- they were on the Mac
    /// this was written on -- and absent means on.
    static func securityUpdates(configData: Bool?, critical: Bool?) -> State {
        if configData == false || critical == false { return .off }
        if configData == true && critical == true { return .on }
        return .defaultOn
    }

    // MARK: - XProtect

    struct XProtectInfo: Equatable {
        let version: String
        let updated: Date?
    }

    /// The version of the malware definitions macOS is using, and when they
    /// last changed. The bundle moved out of `/System` in macOS 11; both
    /// places are tried, newest location first.
    static func xprotect() -> XProtectInfo? {
        for path in ["/Library/Apple/System/Library/CoreServices/XProtect.bundle",
                     "/System/Library/CoreServices/XProtect.bundle"] {
            let bundle = URL(fileURLWithPath: path)
            guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                  let version = info["CFBundleShortVersionString"] as? String else { continue }
            let updated = (try? bundle.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return XProtectInfo(version: version, updated: updated)
        }
        return nil
    }

    // MARK: - Running the checks

    struct Report: Equatable {
        var states: [Check: State]
        var xprotect: XProtectInfo?

        /// Essential protections that are off, in the order they are listed.
        var essentialOff: [Check] {
            Check.allCases.filter { $0.isEssential && states[$0] == .off }
        }
    }

    /// Every check. Blocking -- four short processes -- so off the main thread.
    static func read() -> Report {
        var states: [Check: State] = [:]
        states[.sip] = parseSIP(run("/usr/bin/csrutil", ["status"]))
        states[.gatekeeper] = parseGatekeeper(run("/usr/sbin/spctl", ["--status"]))
        states[.fileVault] = parseFileVault(run("/usr/bin/fdesetup", ["status"]))
        states[.firewall] = parseFirewall(run("/usr/libexec/ApplicationFirewall/socketfilterfw",
                                              ["--getglobalstate"]))
        let domain = "com.apple.SoftwareUpdate" as CFString
        let configData = CFPreferencesCopyAppValue("ConfigDataInstall" as CFString, domain) as? Bool
        let critical = CFPreferencesCopyAppValue("CriticalUpdateInstall" as CFString, domain) as? Bool
        states[.securityUpdates] = securityUpdates(configData: configData, critical: critical)
        return Report(states: states, xprotect: xprotect())
    }

    /// What a tool printed, both streams. Empty if it could not be run, which
    /// every parser above reads as `.unknown`.
    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
