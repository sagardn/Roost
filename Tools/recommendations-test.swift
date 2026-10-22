//
//  recommendations-test.swift
//
//  Exercises the advice the Check-up gives: when a finding earns a row, how
//  the rows are ordered, and when a repeated finding is news.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Palette.swift \
//            Roost/Monitor/Readings.swift Roost/Monitor/DiskReadings.swift \
//            Roost/Monitor/MemoryReadings.swift Roost/System/Protection.swift \
//            Roost/System/Recommendations.swift Tools/recommendations-test.swift | swift -
//
//  Advice fails by being noisy more often than by being wrong: a row for
//  40 MB, the same warning at every scan, a "speed up your Mac" nobody can
//  measure. Most of these cases are about what must not appear.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias R = Recommendations
let gb: UInt64 = 1_073_741_824
let mb: Int64 = 1_048_576

func volume(total: UInt64, free: UInt64, freeNow: UInt64? = nil) -> DiskReadings.Volume {
    DiskReadings.Volume(name: "Macintosh HD", path: "/", total: total, free: free,
                        freeNow: freeNow ?? free, isRemovable: false, isInternal: true, format: "APFS")
}
func ids(_ inputs: R.Inputs) -> [String] { R.make(inputs).map(\.id) }

print("Nothing to say")
check("an empty scan says nothing", R.make(R.Inputs()).isEmpty)
var calm = R.Inputs()
calm.disk = volume(total: 500 * gb, free: 300 * gb)
calm.memoryPressure = .normal
calm.thermalState = 0
calm.cleanupTicked = 10 * mb
calm.cleanupReview = 20 * mb
calm.duplicateBytes = 40 * mb
calm.duplicateGroups = 3
calm.protection = Protection.Report(states: [.sip: .on, .gatekeeper: .on, .fileVault: .on,
                                             .firewall: .on, .securityUpdates: .defaultOn], xprotect: nil)
calm.jobsMissingProgram = 0
calm.jobsUnsigned = 0
check("a healthy Mac with small findings says nothing", R.make(calm).isEmpty)
var warnPressure = calm
warnPressure.memoryPressure = .warning
check("memory pressure at warning is not a row -- macOS is coping", R.make(warnPressure).isEmpty)
var fair = calm
fair.thermalState = 1
check("a 'fair' thermal state is not a row", R.make(fair).isEmpty)

print("Disk")
var tight = calm
tight.disk = volume(total: 500 * gb, free: 40 * gb)       // 92% used
check("past the menu bar's amber line, a suggestion", R.make(tight).first.map {
    $0.id == "disk.full" && $0.severity == .suggestion } == true)
tight.disk = volume(total: 500 * gb, free: 20 * gb)       // 96% used
check("past its red line, a warning", R.make(tight).first.map {
    $0.id == "disk.full" && $0.severity == .warning } == true)
tight.disk = volume(total: 500 * gb, free: 20 * gb, freeNow: 8 * gb)
check("purgeable space is pointed at when the disk is tight", ids(tight).contains("disk.purgeable"))
var roomy = calm
roomy.disk = volume(total: 500 * gb, free: 300 * gb, freeNow: 200 * gb)
check("but not on a roomy disk, where it is macOS doing its job", !ids(roomy).contains("disk.purgeable"))
var empty = calm
empty.disk = volume(total: 0, free: 0)
check("a volume reporting no capacity says nothing", !ids(empty).contains("disk.full"))

print("Findings")
var found = calm
found.cleanupTicked = 80 * mb
found.cleanupReview = 30 * mb
check("findings over the threshold together earn a row", ids(found).contains("cleanup.found"))
found.cleanupTicked = 0
found.cleanupReview = 200 * mb
let reviewOnly = R.make(found).first { $0.id == "cleanup.found" }
check("findings that are all for review still do", reviewOnly != nil)
check("and every cleanup row asks before acting", reviewOnly?.needsConfirmation == true)
found.duplicateBytes = 150 * mb
check("duplicates over the threshold earn a row", ids(found).contains("duplicates.found"))

print("Protections")
var exposed = calm
exposed.protection = Protection.Report(states: [.sip: .off, .gatekeeper: .on, .fileVault: .off,
                                                .firewall: .off, .securityUpdates: .unknown], xprotect: nil)
let rows = R.make(exposed)
check("SIP off is a warning", rows.first { $0.id == "protection.sip" }?.severity == .warning)
check("FileVault off is a warning", rows.first { $0.id == "protection.fileVault" }?.severity == .warning)
check("the firewall off is only a note", rows.first { $0.id == "protection.firewall" }?.severity == .note)
check("an unknown state is never reported as off", !rows.contains { $0.id == "protection.securityUpdates" })
check("Gatekeeper on says nothing", !rows.contains { $0.id == "protection.gatekeeper" })

print("Health")
var strained = calm
strained.memoryPressure = .critical
strained.thermalState = 2
check("critical memory pressure is a warning", ids(strained).contains("memory.pressure"))
check("a serious thermal state is a warning", ids(strained).contains("thermal"))
let memory = R.make(strained).first { $0.id == "memory.pressure" }
check("the memory row never promises to clean memory",
      memory.map { !$0.action.lowercased().contains("clean") && !$0.action.lowercased().contains("purge") } == true)

print("Background jobs")
var jobs = calm
jobs.jobsMissingProgram = 2
jobs.jobsUnsigned = 1
check("a job with a missing program is a suggestion",
      R.make(jobs).first { $0.id == "jobs.missing" }?.severity == .suggestion)
check("an unsigned one is only a note, and an inference",
      R.make(jobs).first { $0.id == "jobs.unsigned" }.map { $0.severity == .note && $0.confidence == .inferred } == true)

print("Order")
var everything = exposed
everything.disk = volume(total: 500 * gb, free: 40 * gb)
everything.cleanupTicked = 900 * mb
everything.cleanupReview = 0
everything.duplicateBytes = 300 * mb
everything.duplicateGroups = 4
let ordered = R.make(everything)
check("worst first", zip(ordered, ordered.dropFirst()).allSatisfy { $0.severity >= $1.severity })
let suggestions = ordered.filter { $0.severity == .suggestion }.map(\.id)
check("the full disk leads the suggestions it is the reason for", suggestions.first == "disk.full")
check("then by what each would give back",
      suggestions == ["disk.full", "cleanup.found", "duplicates.found"])

func rec(_ id: String, _ severity: R.Severity, _ bytes: Int64 = 0) -> R.Recommendation {
    R.Recommendation(id: id, severity: severity, confidence: .measured, problem: id, evidence: "",
                     benefit: "", risk: "", action: "", needsConfirmation: false,
                     destination: .checkUpList, bytes: bytes)
}
let deduped = R.ranked([rec("a", .note), rec("a", .warning), rec("b", .note)])
check("one row per id, the first kept", deduped.map(\.id) == ["a", "b"] && deduped[0].severity == .note)
let ties = R.ranked([rec("x", .note), rec("y", .note), rec("z", .note)])
check("ties keep the order the rules run in", ties.map(\.id) == ["x", "y", "z"])

print("What is news")
let before = [rec("disk.full", .suggestion), rec("cleanup.found", .suggestion)]
let after = [rec("disk.full", .suggestion), rec("cleanup.found", .suggestion), rec("thermal", .warning)]
check("a new condition is news", R.new(after, since: before).map(\.id) == ["thermal"])
check("an unchanged one is not", R.new(before, since: before).isEmpty)
check("one that got worse is", R.new([rec("disk.full", .warning)], since: before).map(\.id) == ["disk.full"])
check("one that got better is not", R.new([rec("disk.full", .note)], since: before).isEmpty)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
