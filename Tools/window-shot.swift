#!/usr/bin/env swift
//
//  window-shot.swift
//
//  Prints the screen rect of Roost's frontmost panel, for screencapture -R.
//
//  Why not screencapture -l<windowid>: capturing a window on its own returns
//  it with a transparent background, and these popups are glass -- the blur
//  they show is the desktop behind them, which a window-only capture throws
//  away. Capturing the region keeps what the eye actually sees.
//
//  Usage: swift Tools/window-shot.swift [owner]
//

import AppKit

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Roost"

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("cannot list windows\n".data(using: .utf8)!)
    exit(1)
}

// The popup is the owner's largest on-screen window: the menu bar items are
// windows too, and they are a few points tall.
let candidates = windows.compactMap { info -> (CGRect, Int)? in
    guard (info[kCGWindowOwnerName as String] as? String) == owner,
          let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
          let layer = info[kCGWindowLayer as String] as? Int,
          rect.height > 200 else { return nil }
    return (rect, layer)
}

guard let best = candidates.max(by: { $0.0.height < $1.0.height }) else {
    FileHandle.standardError.write("no \(owner) window taller than 200pt is on screen\n".data(using: .utf8)!)
    exit(2)
}

let r = best.0
// screencapture -R takes x,y,w,h in top-left origin points, which is the same
// coordinate space CGWindowListCopyWindowInfo reports.
print("\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))")
