//
//  formername-test.swift
//
//  Exercises the move from the app's old name: which settings come across,
//  under what keys, how often, and when the bundle renames itself.
//
//  Run:  cat Roost/Startup/FormerName.swift Tools/formername-test.swift | swift -
//
//  The case worth having a test for is the second launch. A migration that
//  runs again after "Reset settings" brings back everything the user just
//  cleared, and nothing on screen would say why.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let plan = FormerName.Plan.self
let newID = "com.sagar.roost"

print("Keys that carry the bundle identifier")
check("a window frame key follows the identifier",
      plan.renamed("NSWindow Frame com.sagar.perch.Settings.WindowFrame", to: newID)
        == "NSWindow Frame com.sagar.roost.Settings.WindowFrame")
check("a key without it is left alone",
      plan.renamed("CPU_state", to: newID) == "CPU_state")
let nested: [String: Any] = ["com.sagar.perch": 1.5, "com.hnc.Discord": 2.5]
let renamedNested = plan.renamedKeys(nested, to: newID) as? [String: Any] ?? [:]
check("a nested map keyed by bundle identifier is renamed inside",
      renamedNested["com.sagar.roost"] as? Double == 1.5 && renamedNested["com.sagar.perch"] == nil)
check("other apps in the nested map are untouched",
      renamedNested["com.hnc.Discord"] as? Double == 2.5)
check("a value that is not a dictionary passes through",
      plan.renamedKeys("com.sagar.perch", to: newID) as? String == "com.sagar.perch")

print("What comes across")
let old: [String: Any] = ["CPU_state": true, "version": "1.0.19",
                          "NSWindow Frame com.sagar.perch.Settings.WindowFrame": "0 0 10 10"]
let merged: [String: Any] = plan.defaults(old: old, current: [:], newIdentifier: newID) ?? [:]
check("every setting comes across", merged["CPU_state"] as? Bool == true)
check("the version comes too, so Startup does not take it for a first run",
      merged["version"] as? String == "1.0.19")
check("under the new key", merged["NSWindow Frame com.sagar.roost.Settings.WindowFrame"] != nil)
check("and not the old one", merged["NSWindow Frame com.sagar.perch.Settings.WindowFrame"] == nil)
let kept: [String: Any] = plan.defaults(old: old, current: ["CPU_state": false],
                                        newIdentifier: newID) ?? [:]
check("a setting Roost already has wins over Perch's", kept["CPU_state"] as? Bool == false)

print("When nothing comes across")
check("no old domain: nothing to do", plan.defaults(old: nil, current: [:], newIdentifier: newID) == nil)
check("an empty old domain: nothing to do", plan.defaults(old: [:], current: [:], newIdentifier: newID) == nil)
var marked = old
marked[FormerName.markerKey] = true
check("an old domain already carried across is not carried again",
      plan.defaults(old: marked, current: [:], newIdentifier: newID) == nil)
check("which holds after Reset settings has emptied the new domain",
      plan.defaults(old: marked, current: [:], newIdentifier: newID) == nil
        && plan.defaults(old: old, current: [:], newIdentifier: newID) != nil)
check("the marker is not copied into the new domain", merged[FormerName.markerKey] == nil)

print("The bundle's name")
let perchApp = URL(fileURLWithPath: "/Applications/Perch.app")
check("Perch.app moves to Roost.app beside it",
      plan.renamedBundle(perchApp, roostExists: { _ in false })?.path == "/Applications/Roost.app")
check("unless a Roost.app is already there",
      plan.renamedBundle(perchApp, roostExists: { _ in true }) == nil)
check("Roost.app stays where it is",
      plan.renamedBundle(URL(fileURLWithPath: "/Applications/Roost.app"), roostExists: { _ in false }) == nil)
check("so does a copy someone renamed themselves",
      plan.renamedBundle(URL(fileURLWithPath: "/Applications/Roost 2.app"), roostExists: { _ in false }) == nil)
check("in ~/Applications as well as /Applications",
      plan.renamedBundle(URL(fileURLWithPath: "/Users/a/Applications/Perch.app"),
                         roostExists: { _ in false })?.path == "/Users/a/Applications/Roost.app")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
