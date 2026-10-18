//
//  windows-probe.swift
//
//  Prints what WindowControl.windowList(for:) can see, for every running app.
//
//  A probe, not a suite: it asserts nothing, it reports. It needs a live
//  desktop and Accessibility permission, and what it prints is whatever
//  happens to be open -- which is why it is not in Tools/run-tests.sh and
//  does not carry a -test name. Named one it would have been counted as a
//  suite that passed, while checking nothing at all.
//
//  Reported as "if any app 3 windo open i can witch in2 windo in my app".
//  Electron apps publish nothing through kAXWindowsAttribute, so the Windows
//  section never appeared for them; this shows the Accessibility count beside
//  the count Roost ends up with, which is the thing that was wrong.
//
//  Run:  cat Roost/Launcher/WindowControl.swift Roost/Launcher/AppEntry.swift \
//            Tools/windows-probe.swift | swift -
//
import AppKit

/// WindowControl reports failures through Notify; irrelevant here.
enum Notify {
    static func show(_ text: String, symbol: String = "", for seconds: TimeInterval = 2) {}
}

print(String(format: "%-24@ %5@ %5@  windows", "app" as NSString, "AX" as NSString, "shown" as NSString))
for app in WindowControl.runningRegularApps() {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
    let axCount = (raw as? [AXUIElement])?.count ?? 0

    let list = WindowControl.windowList(for: app)
    guard axCount > 0 || !list.isEmpty else { continue }
    print(String(format: "%-24@ %5d %5d", (app.localizedName ?? "?") as NSString, axCount, list.count))
    for w in list {
        let via: String
        switch w.handle {
        case .window: via = "ax  "
        case .menuItem: via = "menu"
        }
        print("    \(via) \(w.isMinimized ? "min " : "    ") \(w.title)")
    }
}
