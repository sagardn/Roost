//
//  runaway-test.swift
//
//  Exercises the runaway-app alert: when it fires, who it names, and that
//  the CPU time it reads from the kernel is in the right unit.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/RunawayApps.swift Tools/runaway-test.swift | swift -
//
//  The unit check is the one that matters most. proc_pidinfo reports CPU
//  time in Mach ticks, which on Apple silicon are 1/24 MHz rather than
//  nanoseconds; read raw, every app reads ~40x quieter than it is and the
//  alert never fires. It is compared here against `ps`, which converts.
//
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

print("When it fires")
do {
    var d = RunawayApps.Detector()
    let busy = ["Shortcuts": 59.0, "Mail": 2.0]
    check("not on the first busy sample", d.observe(busy, threshold: 50, samples: 3).isEmpty)
    check("not on the second", d.observe(busy, threshold: 50, samples: 3).isEmpty)
    check("on the third, and only the busy app", d.observe(busy, threshold: 50, samples: 3) == ["Shortcuts"])
    check("once per stretch, not every sample after", d.observe(busy, threshold: 50, samples: 3).isEmpty)
    // A dip just under the line breaks the streak but is not "calm".
    _ = d.observe(["Shortcuts": 45], threshold: 50, samples: 3)
    for _ in 0..<3 { _ = d.observe(busy, threshold: 50, samples: 3) }
    check("hovering at the line is not reported again", !d.reported.isEmpty
          && d.observe(busy, threshold: 50, samples: 3).isEmpty)
    // Well under the line is calm; a later stretch is news again.
    _ = d.observe(["Shortcuts": 5], threshold: 50, samples: 3)
    check("calm clears the report", !d.reported.contains("Shortcuts"))
    var again: [String] = []
    for _ in 0..<3 { again = d.observe(busy, threshold: 50, samples: 3) }
    check("so a later stretch is reported", again == ["Shortcuts"])
    check("a spike that ends is never reported", {
        var e = RunawayApps.Detector()
        _ = e.observe(["X": 300], threshold: 50, samples: 3)
        _ = e.observe(["X": 300], threshold: 50, samples: 3)
        return e.observe(["X": 1], threshold: 50, samples: 3).isEmpty
    }())
    _ = d.observe([:], threshold: 50, samples: 3)
    check("an app that quit is forgotten", d.streak.isEmpty && d.reported.isEmpty)
}

print("\nWho it names")
do {
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    let owner = RunawayApps.owner(of: helper)
    check("a helper belongs to its outermost app", owner.name == "Google Chrome"
          && owner.bundle?.path == "/Applications/Google Chrome.app")
    let tool = RunawayApps.owner(of: "/opt/homebrew/bin/node")
    check("a command-line tool is named by its file, with no app", tool.name == "node" && tool.bundle == nil)
    let system = RunawayApps.owner(of: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    check("a system app is still an app", system.name == "Finder")
    // roost-06's real paths: a toolchain binary inside Xcode is not Xcode.
    for tool in ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                 "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                 "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"] {
        let o = RunawayApps.owner(of: tool)
        check("\((tool as NSString).lastPathComponent) is itself, not Xcode, and has no Quit",
              o.name == (tool as NSString).lastPathComponent && o.bundle == nil)
    }
    check("Xcode's own executable is still Xcode",
          RunawayApps.owner(of: "/Applications/Xcode.app/Contents/MacOS/Xcode").bundle?.lastPathComponent == "Xcode.app")

print("\nmacOS's own processes")
    check("StorageManagementService is never reported",
          RunawayApps.isSystem("/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/Resources/StorageManagementService.app/Contents/MacOS/StorageManagementService"))
    check("nor Apple's parts of /usr", RunawayApps.isSystem("/usr/libexec/trustd")
          && RunawayApps.isSystem("/usr/bin/yes") && RunawayApps.isSystem("/usr/sbin/cfprefsd"))
    check("but Homebrew on Intel, in /usr/local, is reported", !RunawayApps.isSystem("/usr/local/bin/node"))
    check("an app in /Applications is", !RunawayApps.isSystem("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    check("a Homebrew tool is", !RunawayApps.isSystem("/opt/homebrew/bin/node"))
}

print("\nThe kernel's numbers, in the right unit")
do {
    // A child that does nothing but burn CPU, read two ways: through
    // RunawayApps' conversion, and by ps, which converts for itself.
    // A busy loop compiled here, outside /usr/bin: `yes` itself is macOS's
    // own and excluded from the alert -- the point of the exclusion -- and a
    // copied system binary loses its signature and will not run.
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("roost-burner-\(getpid())")
    let source = copy.appendingPathExtension("c")
    try! "int main(void) { volatile unsigned long n = 0; for (;;) n++; }".write(to: source, atomically: true, encoding: .utf8)
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-O0", "-o", copy.path, source.path]
    try! cc.run(); cc.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: copy); try? FileManager.default.removeItem(at: source) }
    let burner = Process()
    burner.executableURL = copy
    try! burner.run()
    Thread.sleep(forTimeInterval: 2)

    let ours = RunawayApps.cpuByApp().first { $0.key == copy.lastPathComponent }?.cpuNanoseconds ?? 0
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "time=", "-p", "\(burner.processIdentifier)"]
    let pipe = Pipe(); ps.standardOutput = pipe
    try! ps.run(); ps.waitUntilExit()
    burner.terminate()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = text.split(separator: ":")
    let psSeconds = (Double(parts.first ?? "0") ?? 0) * 60 + (Double(parts.last ?? "0") ?? 0)
    let oursSeconds = Double(ours) / 1e9
    check("the burner used real CPU, by ps (\(psSeconds)s)", psSeconds > 0.5)
    // Read a moment apart, so not identical -- but within a factor of 1.5,
    // where unconverted ticks on Apple silicon would be ~40x out.
    check("ours agrees with ps (\(String(format: "%.2f", oursSeconds))s vs \(psSeconds)s)",
          psSeconds > 0 && oursSeconds / psSeconds > 0.66 && oursSeconds / psSeconds < 1.5)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
