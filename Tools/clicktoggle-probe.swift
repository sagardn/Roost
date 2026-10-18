//
//  clicktoggle-probe.swift
//
//  Clicks TextEdit in the launcher, over and over, and checks what happened
//  to its windows each time: the live half of clicktoggle-test.swift.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Launcher/Notify.swift \
//            Roost/Launcher/AppEntry.swift Roost/Launcher/ClickToggle.swift \
//            Roost/Launcher/WindowControl.swift Tools/clicktoggle-probe.swift | swift -
//
//  A probe, not a suite -- the runner leaves *-probe files alone -- because
//  it needs what CI has neither of: a desktop, and a process granted
//  Accessibility. It launches, minimises, hides and quits TextEdit, so it
//  refuses to start while TextEdit is already open: it would be someone's
//  documents it was minimising.
//
//  Full screen is not driven here. Entering it moves the whole display to a
//  new Space for a second and a half each way, and the decision it leads to
//  is pure and covered by the suite.
//
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let bundleID = "com.apple.TextEdit"
let entry = AppEntry(name: "TextEdit", bundleID: bundleID)

guard AXIsProcessTrusted() else {
    print("needs Accessibility for the process running this script"); exit(2)
}
guard WindowControl.runningApp(bundleID) == nil else {
    print("TextEdit is open; quit it first -- this would minimise its windows"); exit(2)
}

/// Lets the other process act, then reads again until `done` holds.
func wait(_ seconds: Double = 4, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if done() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return done()
}

func app() -> NSRunningApplication? { WindowControl.runningApp(bundleID) }
func windows() -> [AXUIElement] {
    guard let app = app() else { return [] }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                  kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).filter {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &role)
        return role as? String == kAXWindowRole
    }
}
func minimized(_ window: AXUIElement) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
    return value as? Bool ?? false
}
var onScreen: Int { windows().filter { !minimized($0) }.count }
var down: Int { windows().filter(minimized).count }
var isFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

func click(activeApp: String? = nil) {
    WindowControl.invalidateAllStates()
    WindowControl.toggle(entry, activeApp: activeApp)
}

/// Something else in front, without touching anything of the person's.
func putFinderInFront() {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first.map(WindowControl.activate)
    _ = wait { !isFront }
}

// Plain text files, so TextEdit opens a document window rather than the
// iCloud open panel, and has nothing to ask about saving when it quits.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roost-clicktoggle-\(getpid())")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let files = (1...2).map { folder.appendingPathComponent("window \($0).txt") }
for file in files { try! "Roost click-toggle probe".write(to: file, atomically: true, encoding: .utf8) }

func open(_ file: URL) {
    let config = NSWorkspace.OpenConfiguration()
    let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)!
    NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: config)
}

func quit() {
    guard let running = app() else { return }
    running.terminate()
    if !wait(6, until: { app() == nil }) { running.forceTerminate() }
    _ = wait { app() == nil }
}
defer { quit() }

print("Not running")
click()
check("a click launches it", wait(8) { app() != nil })
quit()

print("\nIn front, one window")
open(files[0])
_ = wait(8) { onScreen == 1 && isFront }
check("set up: TextEdit in front with one window", onScreen == 1 && isFront)
click()
check("a click minimises it", wait { down == 1 && onScreen == 0 })

print("\nAll minimised")
click()
check("a click restores it", wait { onScreen == 1 && down == 0 })
check("and it is in front", wait { isFront })

print("\nBehind another app")
putFinderInFront()
check("set up: Finder in front", !isFront)
click()
check("a click brings it to the front", wait { isFront })
check("without minimising anything", onScreen == 1 && down == 0)

print("\nIn front, two windows")
open(files[1])
_ = wait(6) { onScreen == 2 && isFront }
check("set up: two windows", onScreen == 2 && isFront)
click()
check("a click minimises both", wait { down == 2 && onScreen == 0 })
click()
check("the next brings both back", wait { onScreen == 2 && down == 0 })

print("\nPicked from the launcher panel")
putFinderInFront()
// The panel passes the app that was in front before it opened, whatever is
// frontmost by the time the row is picked.
click(activeApp: bundleID)
check("the app you were in is minimised, not raised", wait { down == 2 })
click()
_ = wait { onScreen == 2 }

print("\nHidden with ⌘H")
app()?.hide()
check("set up: hidden", wait { app()?.isHidden == true })
click()
check("a click unhides it", wait { app()?.isHidden == false })
check("and it is in front", wait { isFront })

print("\nRunning with no window")
for window in windows() {
    var button: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
    if let button { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
}
check("set up: still running, no window", wait { windows().isEmpty } && app() != nil)
click()
check("a click makes it open one", wait(6) { !windows().isEmpty })

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
