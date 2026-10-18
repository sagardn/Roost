//
//  popup-test.swift
//
//  Exercises the words the popups lead with.
//
//  Run:  cat Roost/UI/Palette.swift Roost/UI/Localized.swift Roost/UI/Events.swift \
//            Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift Roost/Monitor/MenuBarStyle.swift \
//            Roost/Monitor/MenuBarWidget.swift Roost/Monitor/Readings.swift \
//            Roost/Monitor/ProcessNetwork.swift Roost/UI/Alert.swift \
//            Roost/Launcher/Notify.swift Roost/Monitor/ProcessControl.swift \
//            Roost/Monitor/PopupSection.swift \
//            Roost/Monitor/PopupParts.swift Tools/popup-test.swift | swift -
//
//  The status line's word and its dot are worked out separately -- the word
//  here, the colour from `Severity` -- so the one thing worth asserting is
//  that they change at the same loads. A popup saying "Busy" beside a calm
//  dot is arguing with itself.
//
import AppKit

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

print("StatusWords.disk")

do {
    check("a half-empty disk has plenty of room", StatusWords.disk(0.5) == "Plenty of room")
    check("just under three quarters still does", StatusWords.disk(0.749) == "Plenty of room")
    // The bug: 87% read "Plenty of room".
    check("87% is filling up, not plenty", StatusWords.disk(0.87) == "Filling up")
    check("and its dot is still calm",
          MenuBarReading.Severity.ofDisk(0.87) == .calm)
    check("at the warning band it is getting full", StatusWords.disk(0.90) == "Getting full")
    check("at the critical band it is almost full", StatusWords.disk(0.95) == "Almost full")
    check("a NaN prints a dash", StatusWords.disk(.nan) == "—")
    // The word may add a step inside calm, but never crosses the colour.
    var crossed = false
    for step in 0...100 {
        let used = Double(step) / 100
        let severity = MenuBarReading.Severity.ofDisk(used)
        let word = StatusWords.disk(used)
        let calmWords: Set<String> = ["Plenty of room", "Filling up"]
        if (severity == .calm) != calmWords.contains(word) { crossed = true }
    }
    check("every calm reading gets a calm word, and only those", !crossed)
}

print("StatusWords.load")

do {
    check("nothing running is idle", StatusWords.load(0) == "Idle")
    check("just under the idle line is idle", StatusWords.load(0.049) == "Idle")
    check("at the idle line it is light", StatusWords.load(0.05) == "Light load")
    check("a NaN prints a dash, not a word", StatusWords.load(.nan) == "—")

    // Every percent from 5 to 100: the word must name the tier the dot is
    // coloured for.
    let expected: [MenuBarReading.Severity: String] = [
        .calm: "Light load", .warning: "Busy", .critical: "Heavy load",
    ]
    var agree = true
    for percent in 5...100 {
        let load = Double(percent) / 100
        if StatusWords.load(load) != expected[MenuBarReading.Severity.of(load: load)] {
            print("       disagree at \(percent)%")
            agree = false
        }
    }
    check("the word changes where the colour does, 5-100%", agree)
}

print("\nSeverity.of(load:)")

do {
    // Severity now reads the load directly instead of comparing the ramp's
    // colour, so its boundaries are written twice. They must not drift: the
    // dot and the chart beside it are coloured by the two.
    var agree = true
    for percent in 0...100 {
        let load = Double(percent) / 100
        if MenuBarReading.Severity.of(load: load).tint !== LoadBand.of(load).color {
            print("       disagree at \(percent)%")
            agree = false
        }
    }
    check("severity and the ramp change colour at the same loads", agree)
}

print("\nSeverityBands")

do {
    typealias S = MenuBarReading.Severity
    // Each boundary from both sides.
    // Literal values, not read back from the bands: a typo in a threshold
    // must fail here rather than move both sides of the check together.
    for (name, bands, below, warning, belowCritical, critical) in [
        ("load", SeverityBands.load, 0.4999, 0.50, 0.7999, 0.80),
        ("disk", SeverityBands.disk, 0.8999, 0.90, 0.9499, 0.95),
        ("temperature", SeverityBands.temperature, 84.99, 85.0, 94.99, 95.0),
    ] {
        check("\(name): calm just below warning", S.of(below, on: bands) == .calm)
        check("\(name): still warning just below critical",
              S.of(belowCritical, on: bands) == .warning)
        check("\(name): warning at its threshold", S.of(warning, on: bands) == .warning)
        check("\(name): critical at its threshold", S.of(critical, on: bands) == .critical)
    }
    check("a NaN is calm, not a crash", S.of(.nan, on: .load) == .calm)
    check("the named helpers use the same bands",
          S.ofDisk(0.91) == .warning && S.ofTemperature(96) == .critical && S.of(load: 0.6) == .warning)
}

print("\nRoostColors hex")

do {
    check("full code", RoostColors.normalised("#0e9ba8") == "#0E9BA8")
    check("no hash", RoostColors.normalised("0E9BA8") == "#0E9BA8")
    check("short code expands", RoostColors.normalised("#f80") == "#FF8800")
    check("whitespace is trimmed", RoostColors.normalised("  #C9302C\n") == "#C9302C")
    check("not hex is refused", RoostColors.normalised("#GGGGGG") == nil)
    check("wrong length is refused", RoostColors.normalised("#12345") == nil)
    check("empty is refused", RoostColors.normalised("") == nil)
    check("a name is refused", RoostColors.normalised("red") == nil)

    // Every default survives the trip through NSColor and back, so the
    // field shows exactly what is stored and "reset" is detectable.
    for which in RoostColors.allCases {
        let color = RoostColors.color(fromHex: which.defaultHex)!
        check("\(which) round-trips", RoostColors.hex(of: color) == which.defaultHex)
    }
}

do {
    // Stored under the user's key and read back as the colour.
    let which = RoostColors.calm
    let before = UserDefaults.standard.string(forKey: which.key)
    defer { UserDefaults.standard.set(before, forKey: which.key) }

    which.set(hex: "#123456")
    check("a choice is stored and used", which.hex == "#123456"
          && RoostColors.hex(of: NSColor.roostCalm) == "#123456")
    check("the same choice is the same colour object", NSColor.roostCalm === NSColor.roostCalm)
    which.set(hex: "nonsense")
    check("a bad code restores the default", which.hex == which.defaultHex && !which.isCustom)
    which.set(hex: which.defaultHex)
    check("choosing the default stores nothing",
          UserDefaults.standard.string(forKey: which.key) == nil)
}

do {
    // The menu bar switch. On unless somebody turns it off.
    let key = "menubar_coloured"
    let before = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(before, forKey: key) }

    UserDefaults.standard.removeObject(forKey: key)
    check("the menu bar is coloured by default", RoostColors.menuBarColoured)
    RoostColors.menuBarColoured = false
    check("switching it off is remembered", !RoostColors.menuBarColoured)
    RoostColors.menuBarColoured = true
    check("and on again", RoostColors.menuBarColoured)
}

// MARK: - The force-quit menu on a process row

print("\nProcessRow context menu")

/// A right-click somewhere inside the row.
func rightClick(in view: NSView) -> NSEvent {
    NSEvent.mouseEvent(with: .rightMouseDown,
                       location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

do {
    let row = ProcessRow()
    row.layoutSubtreeIfNeeded()
    row.set(name: "Google Chrome", pid: 4321, value: "330 MB")

    let menu = row.menu(for: rightClick(in: row))
    check("a row with a live pid offers a menu", menu != nil)
    check("with both Quit and Force Quit", menu?.items.count == 2)
    // Quit first: the top item is where a fast hand lands, and of the two it
    // is the one that lets the process save.
    check("Quit is offered before Force Quit",
          menu?.items.first?.title.hasPrefix("Quit") == true
            && menu?.items.last?.title.contains("Force") == true)
    check("both name the process",
          menu?.items.allSatisfy { $0.title.contains("Google Chrome") } == true)
    check("both are wired to something",
          menu?.items.allSatisfy { $0.action != nil } == true)
    check("and to different things",
          menu?.items.first?.action != menu?.items.last?.action)
    check("targeting the row, not whatever is first responder",
          menu?.items.allSatisfy { $0.target as? NSView === row } == true)
}

do {
    // An empty slot: the lists are built for more rows than are usually
    // filled, and a menu on one would act on pid 0 -- every process in the
    // group.
    let row = ProcessRow()
    row.layoutSubtreeIfNeeded()
    check("an unfilled row offers no menu at all",
          row.menu(for: rightClick(in: row)) == nil)
}

do {
    // The row must answer the click itself. Its children are labels, and a
    // label has no menu and does not pass the question up -- so if hit
    // testing reaches one, right-clicking the process name does nothing,
    // which is the part of the row anybody would aim at.
    let row = ProcessRow()
    row.layoutSubtreeIfNeeded()
    row.set(name: "Discord Helper (Renderer)", pid: 777, value: "147 MB")
    let onTheName = NSPoint(x: 40, y: row.bounds.midY)
    check("a click on the name lands on the row, not a label",
          row.hitTest(onTheName) === row)
    check("and one outside it lands nowhere",
          row.hitTest(NSPoint(x: -20, y: row.bounds.midY)) == nil)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
