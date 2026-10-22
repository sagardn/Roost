import Foundation

/// What is worth doing about this Mac, worst first, with the evidence.
///
/// One engine, so the Check-up and anything else that wants advice get the
/// same advice, worded the same way, from the same thresholds. Every
/// recommendation carries what was measured, how sure the measurement is,
/// what doing it would gain and what it could cost -- because a list that
/// only says "Clean up 3.2 GB" invites the click without the thought, and
/// the thought is the part that keeps somebody's data.
///
/// What it will not say is as deliberate as what it does:
///
/// - **No score.** "Your Mac is 72% healthy" is a number nobody can act on
///   and nothing can measure.
/// - **No speed promises.** Moving files to the Bin frees disk, not speed,
///   and a full disk is the only way disk space slows a Mac down. Memory is
///   never "cleaned" -- see `docs/ARCHITECTURE.md` ▸ Cleanup.
/// - **Nothing below the noise.** A 40 MB saving is not worth a row; the
///   thresholds are in `Threshold` and tested.
enum Recommendations {

    enum Severity: Int, Comparable {
        /// Worth knowing; nothing is wrong.
        case note = 0
        /// Worth doing when convenient.
        case suggestion = 1
        /// Worth doing soon: a protection is off, the disk is nearly full.
        case warning = 2

        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum Confidence: Equatable {
        /// A reading of the system itself: free space, a setting.
        case measured
        /// A rule applied to what was found -- an identifier nothing claims,
        /// a signature that is missing. Usually right; shown as a rule.
        case inferred
    }

    /// Where the action is taken.
    enum Destination: Equatable {
        case checkUpList          // the review list below the advice
        case duplicates
        case backgroundItems
        case storageSettings
        case activityMonitor
        case protection(Protection.Check)
    }

    struct Recommendation: Equatable {
        /// Stable across scans, so the same condition is one row and an
        /// unchanged one is recognised as unchanged.
        let id: String
        let severity: Severity
        let confidence: Confidence
        let problem: String
        let evidence: String
        let benefit: String
        let risk: String
        let action: String
        /// Whether acting on it changes anything without a further question.
        /// Nothing here does: every destructive step has its own review and
        /// its own confirmation. True means the destination will ask.
        let needsConfirmation: Bool
        let destination: Destination
        /// Bytes it would give back, for ordering within a severity.
        let bytes: Int64
    }

    /// What the advice is drawn from. Every field optional: a scan that did
    /// not reach something says nothing about it, rather than reporting it as
    /// fine.
    struct Inputs: Equatable {
        var disk: DiskReadings.Volume?
        var memoryPressure: MemoryReadings.Pressure?
        /// `ProcessInfo.ThermalState.rawValue`: 0 nominal ... 3 critical.
        var thermalState: Int?
        /// What the Check-up found that is ticked by default, and all of it.
        var cleanupTicked: Int64?
        var cleanupReview: Int64?
        var duplicateBytes: Int64?
        var duplicateGroups: Int?
        var protection: Protection.Report?
        var jobsMissingProgram: Int?
        var jobsUnsigned: Int?
    }

    /// Below these, a finding is not worth a row of its own.
    enum Threshold {
        static let cleanup: Int64 = 100 * 1_048_576
        static let duplicates: Int64 = 100 * 1_048_576
        /// Purgeable space worth pointing at, and only when the disk is tight
        /// -- on a roomy disk it is macOS doing its job.
        static let purgeable: UInt64 = 5 * 1_073_741_824
    }

    // MARK: - The rules

    static func make(_ inputs: Inputs) -> [Recommendation] {
        ranked(diskRules(inputs) + findingRules(inputs) + healthRules(inputs)
               + protectionRules(inputs) + jobRules(inputs))
    }

    /// Free space, judged by the bands the menu bar colours the disk with.
    private static func diskRules(_ inputs: Inputs) -> [Recommendation] {
        var out: [Recommendation] = []
        if let disk = inputs.disk, disk.total > 0 {
            let zone = SeverityBands.disk.zone(disk.percent)
            if zone > 0 {
                out.append(Recommendation(
                    id: "disk.full",
                    severity: zone == 2 ? .warning : .suggestion,
                    confidence: .measured,
                    problem: localized("The startup disk is nearly full"),
                    evidence: localized("%0 available of %1", Readings.size(disk.free),
                                        Readings.size(disk.total)),
                    benefit: localized("macOS needs free space to install updates and to swap memory to disk. Roost says so when the menu bar turns amber."),
                    risk: localized("None in looking. Whatever you remove is your choice, one item at a time."),
                    action: localized("Review what can go"),
                    needsConfirmation: true, destination: .checkUpList,
                    // Not a saving -- nothing is freed by reading this row --
                    // but the reason for every other row, so it sorts first
                    // among the suggestions.
                    bytes: .max))
                if disk.purgeable >= Threshold.purgeable {
                    out.append(Recommendation(
                        id: "disk.purgeable",
                        severity: .note,
                        confidence: .measured,
                        problem: localized("macOS is holding space it can give back"),
                        evidence: localized("%0 macOS can reclaim", Readings.size(disk.purgeable)),
                        benefit: localized("Snapshots and caches macOS frees by itself when space runs short. Storage settings shows what they are."),
                        risk: localized("None. macOS decides what to release."),
                        action: localized("Open Storage settings"),
                        needsConfirmation: false, destination: .storageSettings,
                        bytes: Int64(clamping: disk.purgeable)))
                }
            }
        }
        return out
    }

    /// What the finders found, once it is worth a row.
    private static func findingRules(_ inputs: Inputs) -> [Recommendation] {
        var out: [Recommendation] = []
        let bytes = { (value: Int64) in Readings.size(UInt64(max(0, value))) }
        if let ticked = inputs.cleanupTicked, let review = inputs.cleanupReview,
           ticked + review >= Threshold.cleanup {
            out.append(Recommendation(
                id: "cleanup.found",
                severity: .suggestion,
                confidence: .inferred,
                problem: localized("Files that have done their job"),
                evidence: ticked > 0
                    ? localized("%0 ready to go, %1 more to look at", bytes(ticked), bytes(review))
                    : localized("%0 to look at", bytes(review)),
                benefit: localized("Disk space, once the Bin is emptied."),
                risk: localized("Low. Only caches, logs and finished downloads arrive ticked, and everything goes to the Bin."),
                action: localized("Review the list"),
                needsConfirmation: true, destination: .checkUpList,
                bytes: ticked + review))
        }

        if let duplicates = inputs.duplicateBytes, let groups = inputs.duplicateGroups,
           duplicates >= Threshold.duplicates {
            out.append(Recommendation(
                id: "duplicates.found",
                severity: .suggestion,
                confidence: .measured,
                problem: localized("Files stored more than once"),
                evidence: localized("%0 sets of identical files, %1 in spare copies", String(groups), bytes(duplicates)),
                benefit: localized("Disk space, once the Bin is emptied."),
                risk: localized("You choose which copy to keep. Roost never lets the last one go."),
                action: localized("Review duplicates"),
                needsConfirmation: true, destination: .duplicates,
                bytes: duplicates))
        }
        return out
    }

    /// Memory and heat, only at the levels where macOS itself is struggling.
    private static func healthRules(_ inputs: Inputs) -> [Recommendation] {
        var out: [Recommendation] = []
        if let pressure = inputs.memoryPressure, pressure == .critical {
            out.append(Recommendation(
                id: "memory.pressure",
                severity: .warning,
                confidence: .measured,
                problem: localized("Memory is under pressure"),
                evidence: localized("macOS reports memory pressure as critical."),
                // No purge button, deliberately: what a purge drops is the
                // file cache, and that only makes the next read slower --
                // see docs/ARCHITECTURE.md ▸ Cleanup.
                benefit: localized("Quitting an app you are not using gives its memory back. Roost does not purge memory; that only slows the next read."),
                risk: localized("Unsaved work in an app you quit."),
                action: localized("Open Activity Monitor"),
                needsConfirmation: false, destination: .activityMonitor,
                bytes: 0))
        }

        if let thermal = inputs.thermalState, thermal >= 2 {
            out.append(Recommendation(
                id: "thermal",
                severity: .warning,
                confidence: .measured,
                problem: localized("The Mac is hot enough that macOS may slow it down"),
                evidence: thermal >= 3 ? localized("macOS reports its thermal state as critical.")
                                       : localized("macOS reports its thermal state as serious."),
                benefit: localized("Finding the app that is working hardest usually finds the cause."),
                risk: localized("Unsaved work in an app you quit."),
                action: localized("Open Activity Monitor"),
                needsConfirmation: false, destination: .activityMonitor,
                bytes: 0))
        }
        return out
    }

    /// A protection reported off. Unknown is never reported as off.
    private static func protectionRules(_ inputs: Inputs) -> [Recommendation] {
        var out: [Recommendation] = []
        if let report = inputs.protection {
            for check in Protection.Check.allCases where report.states[check] == .off {
                out.append(Recommendation(
                    id: "protection." + check.rawValue,
                    severity: check.isEssential ? .warning : .note,
                    confidence: .measured,
                    problem: localized("%0 is off", check.title),
                    evidence: check.purpose,
                    benefit: check.isEssential
                        ? localized("macOS turns this on by default; it is one of the protections every Mac is expected to have.")
                        : localized("Worth turning on if you use public or shared networks."),
                    risk: check == .sip
                        ? localized("If you turned it off for development work, leave it until that is done. It can only be changed from Recovery.")
                        : localized("None that Roost knows of. The switch is in System Settings."),
                    action: check == .sip ? localized("How to turn it back on")
                                          : localized("Open System Settings"),
                    needsConfirmation: false, destination: .protection(check),
                    bytes: 0))
            }
        }
        return out
    }

    /// Launch jobs that point at nothing, or at something unsigned.
    private static func jobRules(_ inputs: Inputs) -> [Recommendation] {
        var out: [Recommendation] = []
        if let missing = inputs.jobsMissingProgram, missing > 0 {
            out.append(Recommendation(
                id: "jobs.missing",
                severity: .suggestion,
                confidence: .measured,
                problem: localized("Background items left by removed apps"),
                evidence: localized("Left behind by a removed app: %0", String(missing)),
                benefit: localized("macOS stops trying, and failing, to start them every time you log in."),
                risk: localized("Low. The program they would start is already gone."),
                action: localized("Review background items"),
                needsConfirmation: true, destination: .backgroundItems,
                bytes: 0))
        }

        if let unsigned = inputs.jobsUnsigned, unsigned > 0 {
            out.append(Recommendation(
                id: "jobs.unsigned",
                severity: .note,
                confidence: .inferred,
                problem: localized("Background items from unidentified developers"),
                evidence: localized("From a developer Apple cannot identify: %0", String(unsigned)),
                benefit: localized("Knowing what starts by itself. Unsigned is usually a script or tool you installed, but each is worth recognising."),
                risk: localized("None in looking."),
                action: localized("Review background items"),
                needsConfirmation: false, destination: .backgroundItems,
                bytes: 0))
        }
        return out
    }

    /// Worst first; within a severity, the most to gain first; ties keep the
    /// order the rules run in. One row per id, the first kept.
    static func ranked(_ list: [Recommendation]) -> [Recommendation] {
        var seen = Set<String>()
        let unique = list.filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            if a.element.bytes != b.element.bytes { return a.element.bytes > b.element.bytes }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The ones that are new since `previous` -- for anything that would
    /// announce them. An unchanged condition is not news, and saying it again
    /// at every scan is how advice becomes noise that gets ignored.
    static func new(_ current: [Recommendation], since previous: [Recommendation]) -> [Recommendation] {
        let before = Dictionary(previous.map { ($0.id, $0.severity) }, uniquingKeysWith: { a, _ in a })
        return current.filter { rec in
            guard let was = before[rec.id] else { return true }
            return rec.severity > was
        }
    }
}
