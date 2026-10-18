//
//  settingswindow-test.swift
//
//  Exercises the settings window's name resolution: which page a name opens.
//
//  Run:  cat Roost/Views/SettingsSelection.swift \
//            Tools/settingswindow-test.swift | swift -
//
//  Names reach this from four directions -- the menu bar's gear, a hotkey, an
//  .openModuleSettings notification and AppDelegate's reopen handler -- and a
//  name that resolves wrongly shows somebody the wrong module's switches
//  under the right module's title. None of it raises an error, and the window
//  cannot be instantiated in a script, so the mapping is checked here.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// What the registry reports on a normal Mac.
let modules = ["CPU", "GPU", "RAM", "Disk", "Sensors", "Network"]

func resolve(_ name: String, _ names: [String] = modules) -> SettingsSelection? {
    SettingsSelection.resolve(name, moduleNames: names)
}

// MARK: - The pages

print("SettingsSelection.resolve")

check("a module name opens that module", resolve("CPU") == .module("CPU"))
check("and the last one in the list, not just the first",
      resolve("Network") == .module("Network"))
check("Dashboard opens the dashboard", resolve("Dashboard") == .dashboard)
check("Settings opens the app's own page", resolve("Settings") == .appSettings)
check("Free up space opens the cleanup page", resolve("Free up space") == .cleanup)
check("Search & switcher opens the launcher page", resolve("Search & switcher") == .launcher)

// MARK: - The alias

// "Combined modules" is what the menu bar calls one status item holding every
// reading. There is no page of that name, and before this was resolved in one
// place, only one of the two ways into the window translated it -- so the
// gear worked and the notification silently did nothing.
check("the combined menu bar item opens the dashboard",
      resolve("Combined modules") == .dashboard)

// MARK: - Names that answer to nothing

check("a name nothing answers to resolves to nothing", resolve("Battery") == nil)
check("nor does an empty name", resolve("") == nil)
check("matching is exact, not case-insensitive", resolve("cpu") == nil)
check("and not prefix matching either", resolve("CP") == nil)
check("nor does whitespace pass", resolve(" CPU") == nil)

// nil is the point: the window leaves what it is showing alone. A fallback to
// the dashboard here would mean a typo in a notification silently navigated
// away from the page somebody was reading.
check("a module that is not installed on this Mac is not guessed at",
      resolve("Sensors", ["CPU", "RAM"]) == nil)

// MARK: - Precedence

// A module named "Dashboard" shadows the built-in page, deliberately: the
// module is a real thing with a real page and the built-in names are the
// fallback. Checked because the order of two `if`s is the whole behaviour.
check("a module shadows a built-in page of the same name",
      resolve("Dashboard", ["Dashboard"]) == .module("Dashboard"))
check("the same for the app settings page",
      resolve("Settings", ["Settings"]) == .module("Settings"))
check("and for the cleanup page",
      resolve("Free up space", ["Free up space"]) == .module("Free up space"))
// But the alias is translated before anything is matched, so a module could
// not take it over by being named after it.
check("the alias is translated before modules are matched",
      resolve("Combined modules", ["Combined modules"]) == .dashboard)

// MARK: - What each page is called, and what it carries

print("\nSettingsSelection.name and .isModule")

check("a module reports its own name", SettingsSelection.module("GPU").name == "GPU")
check("the dashboard reports Dashboard", SettingsSelection.dashboard.name == "Dashboard")
check("the app page reports Settings", SettingsSelection.appSettings.name == "Settings")
check("the cleanup page reports Free up space",
      SettingsSelection.cleanup.name == "Free up space")

// .isModule decides the shape of the .openWindow notification: a module's
// page brings that module's menu bar item forward, the other two pages must
// not claim one.
check("only a module is a module", SettingsSelection.module("RAM").isModule)
check("the dashboard is not", !SettingsSelection.dashboard.isModule)
check("the app settings page is not", !SettingsSelection.appSettings.isModule)
// It has no menu bar item to bring forward: it configures nothing and
// belongs to no reading.
check("nor is the cleanup page", !SettingsSelection.cleanup.isModule)
check("nor is the launcher page", !SettingsSelection.launcher.isModule)
check("the launcher page reports its name",
      SettingsSelection.launcher.name == "Search & switcher")

// MARK: - Round trip

print("\nResolving a page's own name returns the same page")

for selection in [SettingsSelection.dashboard, .appSettings, .cleanup, .launcher]
                 + modules.map({ SettingsSelection.module($0) }) {
    check("\(selection.name) survives a round trip",
          resolve(selection.name) == selection)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
