//
//  setup-test.swift
//
//  Exercises the first-run window's flow and what its presets write.
//
//  Run:  cat Roost/UI/Localized.swift \
//            Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift \
//            Roost/Monitor/MenuBarStyle.swift \
//            Roost/Views/SetupFlow.swift \
//            Tools/setup-test.swift | swift -
//
//  The first-run window is shown once per installation and then never again,
//  so nothing about it is ever exercised a second time by anyone. What it
//  writes, though, lasts: `<Module>_state` and `<Module>_widget` are read at
//  every launch for the life of the install, and `_widget` holds MenuBarStyle
//  raw values rather than case names. Renaming a case without renaming its
//  raw value would reset the menu bar of everyone who has ever run setup, and
//  nothing would raise an error. That is what the literal strings below are
//  for -- they fail if the stored vocabulary moves, which is the only way to
//  notice.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: - Walking the pages

print("SetupFlow")

do {
    var flow = SetupFlow()
    check("it opens on the welcome page", flow.page == .welcome)
    check("there is nowhere back from the first page", !flow.canGoBack)
    check("and the first page is not the last", !flow.isFinish)

    check("Next goes to the presets", flow.advance() == .show(.preset))
    check("you can go back from the second page", flow.canGoBack)
    check("then window control", flow.advance() == .show(.windowControl))
    check("then start at login", flow.advance() == .show(.loginItem))
    check("then updates", flow.advance() == .show(.updates))
    check("then the last page", flow.advance() == .show(.done))
}

do {
    var flow = SetupFlow(page: .done)
    check("the last page is the last page", flow.isFinish)
    check("and Next on it finishes rather than showing a sixth page",
          flow.advance() == .finish)
    check("finishing does not move off the last page", flow.page == .done)
}

do {
    // The version this replaces set the button titles in an if / else-if /
    // else on the index, and the branch that restored "Next" was the middle
    // one -- so going back from the last page worked only because the last
    // page is never the second page. Checked here rather than inferred.
    var flow = SetupFlow(page: .done)
    check("the last page's button says Finish", flow.nextTitle == "Finish")
    check("going back from it", flow.goBack() == .updates)
    check("restores Next", flow.nextTitle == "Next")

    var walkedBack: [SetupPage] = [flow.page]
    while flow.canGoBack { walkedBack.append(flow.goBack()) }
    check("and back reaches every page in reverse, without skipping one",
          walkedBack == [.updates, .loginItem, .windowControl, .preset, .welcome])
    check("back from the first page is refused rather than wrapping",
          flow.goBack() == .welcome)
    check("and the first page offers Next again", flow.nextTitle == "Next")
}

do {
    var flow = SetupFlow()
    var seen: [SetupPage] = [flow.page]
    while case .show(let page) = flow.advance() { seen.append(page) }
    check("five pages, in order",
          seen == [.welcome, .preset, .windowControl, .loginItem, .updates, .done])
    check("and the walk terminates", seen.count == SetupPage.allCases.count)
}

// MARK: - What a preset writes

print("\nSetupPreset")

check("four presets are offered", SetupPreset.all.count == 4)
check("named as the window names them",
      SetupPreset.all.map { $0.name } == ["Default", "Basic", "Recommended", "Extended"])
check("Default is the one selected", SetupPreset.defaultIndex == 0)
check("six modules are offered",
      SetupPreset.modules == ["CPU", "GPU", "RAM", "Disk", "Sensors", "Network"])
check("battery is not one of them", !SetupPreset.modules.contains("Battery"))
check("nor bluetooth", !SetupPreset.modules.contains("Bluetooth"))

func preset(_ name: String) -> SetupPreset { SetupPreset.all.first { $0.name == name }! }

do {
    let writes = preset("Default").writes()

    // The whole contract, spelled out. Not "something was written for CPU":
    // these exact strings are what the modules read back, and a test that
    // only checked shape would pass while every existing user's menu bar
    // reset.
    check("Default writes the state and shape of every module it includes",
          writes == [
            .flag(key: "CPU_state", value: true),
            .text(key: "CPU_widget", value: "mini"),
            .flag(key: "GPU_state", value: false),
            .flag(key: "RAM_state", value: true),
            .text(key: "RAM_widget", value: "mini"),
            .flag(key: "Disk_state", value: true),
            .text(key: "Disk_widget", value: "mini"),
            .flag(key: "Sensors_state", value: false),
            .flag(key: "Network_state", value: true),
            .text(key: "Network_widget", value: "speed"),
          ])
}

do {
    // The stored name is "speed", not "rates". The case was renamed when the
    // shapes became Roost's; the raw value could not be, because it is in
    // every existing install's preferences.
    let network = preset("Default").items.first { $0.module == "Network" }!
    check("the rates shape is stored under the name the old module system used",
          network.style.rawValue == "speed")
    let extended = preset("Extended").items.first { $0.module == "Sensors" }!
    check("and the name shape stores as 'label'", extended.style.rawValue == "label")
    let recommended = preset("Recommended").items.first { $0.module == "RAM" }!
    check("and the bar chart as 'bar_chart'", recommended.style.rawValue == "bar_chart")
    let cpu = preset("Extended").items.first { $0.module == "CPU" }!
    check("and the line chart as 'line_chart'", cpu.style.rawValue == "line_chart")
}

do {
    let writes = preset("Basic").writes()
    check("Basic names every module, not only the two it switches on",
          Set(writes.map { $0.key }) == Set([
            "CPU_state", "CPU_widget", "GPU_state", "RAM_state", "RAM_widget",
            "Disk_state", "Sensors_state", "Network_state",
          ]))
    check("so switching from Extended to Basic turns Sensors off",
          writes.contains(.flag(key: "Sensors_state", value: false)))
    check("a module it leaves off gets no shape written",
          !writes.contains { $0.key == "Sensors_widget" })
}

do {
    check("Extended switches on all six",
          preset("Extended").writes().filter {
              if case .flag(_, let on) = $0 { return on }
              return false
          }.count == 6)
    check("and Basic only two",
          preset("Basic").writes().filter {
              if case .flag(_, let on) = $0 { return on }
              return false
          }.count == 2)
}

do {
    for p in SetupPreset.all {
        let keys = p.writes().map { $0.key }
        check("\(p.name) writes each key once", Set(keys).count == keys.count)
        check("\(p.name) names every module", SetupPreset.modules.allSatisfy { module in
            keys.contains("\(module)_state")
        })
        check("\(p.name) names no module twice",
              keys.filter { $0.hasSuffix("_state") }.count == SetupPreset.modules.count)
        check("\(p.name) offers only modules that exist",
              p.items.allSatisfy { SetupPreset.modules.contains($0.module) })
    }
}

do {
    // Every shape a preset uses has to be one the menu bar can draw, or the
    // preset silently produces an empty item.
    let used = Set(SetupPreset.all.flatMap { $0.items.map { $0.style } })
    check("every shape a preset uses is a real shape",
          used.allSatisfy { MenuBarStyle(rawValue: $0.rawValue) != nil })
    check("and the stored value round-trips",
          used.allSatisfy { MenuBarStyle(rawValue: $0.rawValue) == $0 })
}

do {
    // `_widget` holds a comma-separated list and a preset writes exactly one
    // shape into it, so the value has to be the bare raw name. A stray
    // separator would make MenuBarStyles.stored read two names, recognise
    // neither, and fall through to its default -- silently, because an
    // unreadable value is indistinguishable from a fresh install.
    let shapeWrites = SetupPreset.all.flatMap { $0.writes() }.compactMap { write -> String? in
        guard case .text(_, let value) = write else { return nil }
        return value
    }
    check("every shape written is a single bare name",
          shapeWrites.allSatisfy { !$0.contains(",") && $0 == $0.trimmingCharacters(in: .whitespaces) })
    check("and reads back as the shape it names",
          shapeWrites.allSatisfy { MenuBarStyle(rawValue: $0) != nil })
    check("the key it is written under is the one MenuBarStyles reads",
          MenuBarStyles.key("CPU") == "CPU_widget")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
