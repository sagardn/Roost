//
//  clicktoggle-test.swift
//
//  Exercises what one click on an app in the launcher does, in every state
//  an app can be in.
//
//  Run:  cat Roost/Launcher/ClickToggle.swift Tools/clicktoggle-test.swift | swift -
//
//  The live half -- that the Accessibility calls really minimise, restore
//  and reopen a real app's windows -- needs a granted process and a desktop,
//  which CI has neither of, so it is Tools/clicktoggle-probe.swift and is
//  run by hand.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias W = ClickToggle.Window
let plain: W = W(isMain: true)
let other: W = W()
let down: W = W(isMinimized: true)
let ours: W = W(isMinimized: true, minimizedByRoost: true)
let full: W = W(isFullScreen: true, isMain: true)
let stuck: W = W(canMinimize: false, isMain: true)

func app(running: Bool = true, hidden: Bool = false, active: Bool = false,
         launchOnly: Bool = false, _ windows: [W] = []) -> ClickToggle.Action {
    ClickToggle.decide(.init(isRunning: running, isHidden: hidden, isActive: active,
                             launchOnly: launchOnly, windows: windows))
}

print("Not running")
check("launches", app(running: false) == .launch)
check("launches even when it was the active app a moment ago",
      app(running: false, active: true) == .launch)

print("\nIn front")
check("its one window is minimised", app(active: true, [plain]) == .minimize([0]))
check("every window on screen is minimised, so the app is out of the way",
      app(active: true, [plain, other, other]) == .minimize([0, 1, 2]))
check("windows already down are left alone",
      app(active: true, [plain, down, other]) == .minimize([0, 2]))
check("all minimised: restores", app(active: true, [down]) == .restore([0]))
check("no window at all: asks it for one", app(active: true) == .reopen)

print("\nBehind")
check("brought to the front", app([plain]) == .raise)
check("brought forward, not minimised, even with one window down",
      app([down, plain]) == .raise)
check("all minimised: restored", app([down]) == .restore([0]))
check("no window at all: asks it for one", app() == .reopen)

print("\nHidden with ⌘H")
check("unhidden", app(hidden: true, [plain]) == .unhide)
check("unhidden even if it was the active app", app(hidden: true, active: true, [plain]) == .unhide)

print("\nWhat a restore brings back")
check("the windows Roost put down, all of them",
      app(active: true, [ours, down, ours]) == .restore([0, 2]))
check("one window when Roost put none down, not a Dock full",
      app([down, down, down]) == .restore([0]))
check("Roost's windows win even when not listed first",
      app([down, ours]) == .restore([1]))

print("\nFull screen")
check("the active window full screen: says macOS cannot",
      app(active: true, [full]) == .refuseFullScreen)
check("and does not minimise the others behind it",
      app(active: true, [full, other]) == .refuseFullScreen)
check("a full-screen window behind a normal one: the normal one goes",
      app(active: true, [W(isMain: true), W(isFullScreen: true)]) == .minimize([0]))
check("behind, a full-screen app is still brought to the front", app([full]) == .raise)

print("\nWindows that refuse to minimise")
check("only those: the app is hidden instead", app(active: true, [stuck]) == .hide)
check("mixed: the ones that can go, go",
      app(active: true, [stuck, other]) == .minimize([1]))

print("\nLaunch-only entries (Launchpad)")
check("running: brought up, never minimised", app(active: true, launchOnly: true, [plain]) == .raise)
check("not running: launched", app(running: false, launchOnly: true) == .launch)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
