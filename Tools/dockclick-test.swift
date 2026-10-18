//
//  dockclick-test.swift
//
//  Exercises what a click on the Dock means.
//
//  Run:  cat Roost/Launcher/DockClick.swift Tools/dockclick-test.swift | swift -
//
//  Almost every case here is one where Roost must do NOTHING. macOS already
//  launches, raises and restores from a Dock click; the only case it leaves
//  empty is clicking the app you are already in, and that is the only one
//  this may answer. Acting on any of the others would fight the Dock and
//  show up as a window that comes back the moment it is raised.
//
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func item(_ id: String, _ x: CGFloat, running: Bool = true) -> DockClick.Item {
    DockClick.Item(bundleID: id, frame: CGRect(x: x, y: 100, width: 40, height: 40),
                   isRunning: running)
}

let chrome = item("com.google.Chrome", 0)
let mail = item("com.apple.mail", 40)
let notes = item("com.apple.Notes", 80, running: false)
let dock = [chrome, mail, notes]

// MARK: - Which icon was clicked

print("Hit testing")

check("a point inside an icon finds it",
      DockClick.hit(CGPoint(x: 20, y: 120), in: dock) == chrome)
check("the icon next to it is a different app",
      DockClick.hit(CGPoint(x: 60, y: 120), in: dock) == mail)
check("a point past the last icon is nothing",
      DockClick.hit(CGPoint(x: 400, y: 120), in: dock) == nil)
check("a point above the Dock is nothing",
      DockClick.hit(CGPoint(x: 20, y: 400), in: dock) == nil)
// The frames come from the Dock itself, so a Dock on the left reports
// negative x on this Mac and must still hit.
let leftDock = [item("com.apple.finder", -48)]
check("an icon at a negative x still hits",
      DockClick.hit(CGPoint(x: -30, y: 120), in: leftDock) == leftDock[0])

// MARK: - Press and release

print("\nA click is a press and a release on the same icon")

check("same icon", DockClick.isSameClick(press: chrome, release: chrome))
// Dragging from one icon to another is somebody rearranging the Dock.
check("dragged to another icon is not a click",
      !DockClick.isSameClick(press: chrome, release: mail))
check("released off the Dock is not a click",
      !DockClick.isSameClick(press: chrome, release: nil))
check("pressed off the Dock is not a click",
      !DockClick.isSameClick(press: nil, release: chrome))

// MARK: - When Roost may act

print("\nWhat Roost does, which is almost always nothing")

func decide(_ hit: DockClick.Item?, press: String?, now: String?) -> String? {
    DockClick.appToPutAway(hit: hit, frontmostAtPress: press, frontmostNow: now)
}

check("the app you are already in is put away",
      decide(chrome, press: "com.google.Chrome", now: "com.google.Chrome")
        == "com.google.Chrome")

// Everything below is the Dock's job and must be left to it.
check("another app is left alone — the Dock is raising it",
      decide(chrome, press: "com.apple.mail", now: "com.google.Chrome") == nil)
check("an app that was in front but is not now was a raise, not a put-away",
      decide(chrome, press: "com.google.Chrome", now: "com.apple.mail") == nil)
check("an app that is not running is left to the Dock to launch",
      decide(notes, press: "com.apple.Notes", now: "com.apple.Notes") == nil)
check("a click on no icon does nothing", decide(nil, press: "x", now: "x") == nil)
check("nothing in front at all does nothing",
      decide(chrome, press: nil, now: nil) == nil)
// The Finder is always running and has no ordinary quit; clicking it while
// it is in front should still put it away, like any other app.
let finder = item("com.apple.finder", 120)
check("the Finder is not a special case",
      decide(finder, press: "com.apple.finder", now: "com.apple.finder")
        == "com.apple.finder")

// MARK: - Restoring is not putting away

print("\nThere has to be something on screen to put away")

// The reported bug, in full: click Chrome to bring it back from the Dock,
// and it goes straight back down. Minimising an app does not deactivate it,
// so Chrome with every window minimised is still the frontmost app -- and
// the click that restores it looks identical to a click on an app sitting
// in front of you, unless you ask what was on screen before the click.
check("all windows minimised: the click restores, and is left alone",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             hadWindowOnScreen: false) == nil)
check("a window was on screen: put away",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             hadWindowOnScreen: true) == "com.google.Chrome")
// An app whose last window was closed is frontmost with nothing showing;
// clicking its icon asks for a new window, not for silence.
check("frontmost with no window at all: left alone, the Dock opens one",
      DockClick.appToPutAway(hit: mail, frontmostAtPress: "com.apple.mail",
                             frontmostNow: "com.apple.mail",
                             hadWindowOnScreen: false) == nil)

// MARK: - A click that raised the app is not a click that puts it away

print("\nAn app has to have been in front before the click, not because of it")

// The reported bug: one click, and the app went away instead of coming up.
// Reading "who is frontmost" during the click cannot tell the two apart --
// whether the Dock activates on the press or the release is its business --
// so the question is whether the app had settled in front BEFORE the press.
let press = Date()

check("in front since well before the click: put away",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press,
                             activatedAt: press.addingTimeInterval(-3))
        == "com.google.Chrome")

// This is the bug. The click itself raised it, so the activation lands at
// the same moment as the press.
check("raised by this very click: left alone",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press,
                             activatedAt: press) == nil)
check("raised a moment before the press: still left alone",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press,
                             activatedAt: press.addingTimeInterval(-0.1)) == nil)
// Two quick clicks: the first raises, the second must not put away.
check("the second of two quick clicks is left alone",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press,
                             activatedAt: press.addingTimeInterval(-0.25)) == nil)
check("just past the settling time: put away",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press,
                             activatedAt: press.addingTimeInterval(-0.31))
        == "com.google.Chrome")
// Nothing recorded means it has been in front since before Roost started
// watching, which is as settled as an app gets.
check("no activation on record: put away",
      DockClick.appToPutAway(hit: chrome, frontmostAtPress: "com.google.Chrome",
                             frontmostNow: "com.google.Chrome",
                             pressedAt: press, activatedAt: nil)
        == "com.google.Chrome")

// MARK: - The cheap pre-filter

print("\nThe region a click must be in to be worth reading the Dock for")

// Reading the Dock properly is 2.21 ms and the tap sees every left click on
// the machine, so a click nowhere near the Dock has to cost a rectangle
// test. The region is deliberately generous: being too tight would drop a
// real click, being too loose costs one wasted read.
let region = DockClick.region(of: dock)!
check("covers every icon", dock.allSatisfy { region.contains($0.frame.origin) })
check("a click on an icon is inside it", region.contains(CGPoint(x: 20, y: 120)))
check("it reaches past the icons, for magnification",
      region.contains(CGPoint(x: 20, y: 60)) && region.contains(CGPoint(x: -40, y: 120)))
check("but not across the whole screen",
      !region.contains(CGPoint(x: 1400, y: 900)))
check("no icons at all has no region", DockClick.region(of: []) == nil)
check("one icon still gives a region", DockClick.region(of: [chrome]) != nil)

print("")
if failures == 0 { print("all passed") } else { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
