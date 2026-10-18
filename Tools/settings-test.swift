//
//  settings-test.swift
//
//  Exercises Preferences: key compatibility with what Kit's Store wrote,
//  defaults, round-tripping, export/import and reset.
//
//  Run:  cat Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift \
//            Tools/settings-test.swift | swift -
//
//  Every case runs against a scratch UserDefaults suite, so running the tests
//  cannot touch the settings of the Roost installed on this machine.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let suiteName = "roost.settings.test.\(UUID().uuidString)"
let suite = UserDefaults(suiteName: suiteName)!
let prefs = Preferences(defaults: suite, domain: suiteName)

print("Defaults")
check("update interval defaults to once per day", prefs.updateInterval == "Once per day")
check("temperature defaults to system", prefs.temperatureUnits == "system")
check("dock icon is off", prefs.dockIcon == false)
check("combined modules is off", prefs.combinedModules == false)
// The one default that is true. Getting this wrong silently disables the
// combined popup for everyone who never touched the setting.
check("combined details is ON", prefs.combinedPopup == true)

print("Round trip")
prefs.dockIcon = true
check("a bool survives", prefs.dockIcon == true)
prefs.temperatureUnits = "fahrenheit"
check("a string survives", prefs.temperatureUnits == "fahrenheit")
prefs.combinedPopup = false
check("a true default can be set false", prefs.combinedPopup == false)

print("Key compatibility with Kit's Store")
// Kit wrote plain keys into the standard domain. A pane reading a different
// key would silently show defaults to a user who had configured Roost.
suite.set("celsius", forKey: "temperature_units")
check("reads temperature_units", prefs.temperatureUnits == "celsius")
suite.set(true, forKey: "keep_menubar_positions")
check("reads keep_menubar_positions", prefs.keepMenuBarPositions == true)
suite.set("large", forKey: "CombinedModules_spacing")
check("reads CombinedModules_spacing", prefs.combinedSpacing == "large")
prefs.dockIcon = false
check("writes the key Kit read", suite.object(forKey: "dockIcon") as? Bool == false)

print("Explicit false is not a missing key")
// `defaults.bool(forKey:)` returns false for both, so a setting the user
// turned off and one never set look identical unless existence is checked.
let freshName = "roost.settings.test.\(UUID().uuidString)"
let fresh = UserDefaults(suiteName: freshName)!
let p2 = Preferences(defaults: fresh, domain: freshName)
check("unset true-default reads true", p2.combinedPopup == true)
p2.combinedPopup = false
check("explicitly false reads false", p2.combinedPopup == false)
check("existence is distinguishable", p2.exists("CombinedModules_popup"))

print("Change notification")
var fired: String? = "nothing"
let token = NotificationCenter.default.addObserver(
    forName: Preferences.didChange, object: nil, queue: nil) { fired = $0.object as? String }
prefs.dockIcon = true
check("a change posts the key that changed", fired == "dockIcon")
NotificationCenter.default.removeObserver(token)

print("Export and import")
do {
    prefs.temperatureUnits = "fahrenheit"
    prefs.combinedSpacing = "small"
    let data = try prefs.exportAll()
    check("export produces a plist", data.count > 0)

    let targetName = "roost.settings.test.\(UUID().uuidString)"
    let target = UserDefaults(suiteName: targetName)!
    let p3 = Preferences(defaults: target, domain: targetName)
    let count = try p3.importAll(data)
    check("import reports how many keys", count > 0)
    check("imported values are readable", p3.temperatureUnits == "fahrenheit")
    check("and all of them, not a chosen list", p3.combinedSpacing == "small")
} catch {
    check("export/import round trip", false)
}

do {
    let oldKey = "NSWindow Frame com.sagar.perch.Settings.WindowFrame"
    let backup: [String: Any] = [oldKey: "0 0 10 10", "CPU_state": true]
    let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .xml, options: 0)
    let targetName = "roost.settings.test.\(UUID().uuidString)"
    let target = UserDefaults(suiteName: targetName)!
    try Preferences(defaults: target, domain: targetName).importAll(data)
    check("a Perch backup's window frames land under this app's identifier",
          target.string(forKey: "NSWindow Frame \(targetName).Settings.WindowFrame") == "0 0 10 10")
    check("and not under the old one", target.object(forKey: oldKey) == nil)
    check("the rest of a Perch backup imports unchanged", target.bool(forKey: "CPU_state"))
    UserDefaults.standard.removePersistentDomain(forName: targetName)
} catch {
    check("a Perch backup imports", false)
}

do {
    _ = try Preferences(defaults: suite).importAll(Data("not a plist at all".utf8))
    check("junk is rejected", false)
} catch {
    check("junk is rejected", true)
}

// A plist that parses but is not a dictionary must not be accepted either.
do {
    let array = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
    _ = try Preferences(defaults: suite).importAll(array)
    check("a non-dictionary plist is rejected", false)
} catch {
    check("a non-dictionary plist is rejected", true)
}

UserDefaults.standard.removePersistentDomain(forName: suiteName)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
