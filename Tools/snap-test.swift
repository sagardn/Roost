//
//  snap-test.swift
//
//  Exercises where window snapping puts a window.
//
//  Run:  cat Roost/Launcher/Snap.swift Tools/snap-test.swift | swift -
//
//  The screen below is a 1470x956 MacBook Air with a 37pt menu bar on top
//  and a 70pt Dock at the bottom, so its usable area starts at y 70 -- the
//  case where getting AppKit's bottom-left origin wrong puts a window half
//  under the Dock.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}
func same(_ a: CGRect?, _ b: CGRect) -> Bool { a.map { Snap.isClose($0, b) } ?? false }

let visible = CGRect(x: 0, y: 70, width: 1470, height: 849)
let small = CGRect(x: 300, y: 300, width: 600, height: 400)

print("Halves and the cycle")
let left = Snap.frame(for: .leftHalf, in: visible, current: small)
check("left half", same(left, CGRect(x: 0, y: 70, width: 735, height: 849)))
let leftTwoThirds = Snap.frame(for: .leftHalf, in: visible, current: left!)
check("again: two thirds", same(leftTwoThirds, CGRect(x: 0, y: 70, width: 980, height: 849)))
let leftThird = Snap.frame(for: .leftHalf, in: visible, current: leftTwoThirds!)
check("again: one third", same(leftThird, CGRect(x: 0, y: 70, width: 490, height: 849)))
check("again: back to half", same(Snap.frame(for: .leftHalf, in: visible, current: leftThird!), left!))
let right = Snap.frame(for: .rightHalf, in: visible, current: small)
check("right half ends at the right edge", same(right, CGRect(x: 735, y: 70, width: 735, height: 849)))
check("right two thirds is anchored right",
      Snap.frame(for: .rightHalf, in: visible, current: right!).map { abs($0.maxX - visible.maxX) < 1 } ?? false)
check("a left half pressed right goes to the right half, not two thirds",
      same(Snap.frame(for: .rightHalf, in: visible, current: left!), right!))
check("top half sits under the menu bar",
      same(Snap.frame(for: .topHalf, in: visible, current: small), CGRect(x: 0, y: 495, width: 1470, height: 424)))
check("bottom half sits on the Dock, not under it",
      same(Snap.frame(for: .bottomHalf, in: visible, current: small), CGRect(x: 0, y: 70, width: 1470, height: 425)))

print("\nQuarters, maximise, centre")
check("top left", same(Snap.frame(for: .topLeft, in: visible, current: small), CGRect(x: 0, y: 495, width: 735, height: 424)))
check("bottom right", same(Snap.frame(for: .bottomRight, in: visible, current: small), CGRect(x: 735, y: 70, width: 735, height: 424)))
check("maximise fills the usable area exactly", Snap.frame(for: .maximize, in: visible, current: small) == visible)
let centred = Snap.frame(for: .center, in: visible, current: small)!
check("centre keeps the size", centred.size == small.size)
check("and centres it", abs(centred.midX - visible.midX) <= 1 && abs(centred.midY - visible.midY) <= 1)
let huge = CGRect(x: 0, y: 0, width: 3000, height: 2000)
check("centre never makes a window bigger than the screen",
      Snap.frame(for: .center, in: visible, current: huge).map { visible.contains($0) } ?? false)
check("restore and display moves are not a frame here",
      Snap.frame(for: .restore, in: visible, current: small) == nil
        && Snap.frame(for: .nextDisplay, in: visible, current: small) == nil)

print("\nAnother display")
let external = CGRect(x: 1470, y: -200, width: 2560, height: 1415)
let moved = Snap.move(left!, from: visible, to: external)
check("a left half stays a left half", same(moved, CGRect(x: 1470, y: -200, width: 1280, height: 1415)))
let fromBig = Snap.move(CGRect(x: 1470, y: -200, width: 2560, height: 1415), from: external, to: visible)
check("a full window shrinks to fit a smaller screen", visible.contains(fromBig))
let corner = Snap.move(CGRect(x: 1400, y: 800, width: 400, height: 300), from: visible, to: external)
check("a window is kept wholly on the target", external.contains(corner))

print("\nWhich screen")
check("the screen holding the centre", Snap.screenIndex(for: small, among: [visible, external]) == 0)
check("a window across both goes by its centre",
      Snap.screenIndex(for: CGRect(x: 1300, y: 300, width: 600, height: 300), among: [visible, external]) == 1)
check("no screens, no answer", Snap.screenIndex(for: small, among: []) == nil)

print("\nCoordinates")
let primaryHeight: CGFloat = 956
let axFrame = CGRect(x: 100, y: 37, width: 800, height: 600)   // just under the menu bar
let appKit = Snap.appKit(fromAX: axFrame, primaryHeight: primaryHeight)
check("top-left becomes bottom-left", appKit == CGRect(x: 100, y: 319, width: 800, height: 600))
check("and converts back exactly", Snap.ax(fromAppKit: appKit, primaryHeight: primaryHeight) == axFrame)
let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)  // a display above the primary
check("a display above the primary comes out above it",
      Snap.appKit(fromAX: above, primaryHeight: primaryHeight).minY == primaryHeight)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
