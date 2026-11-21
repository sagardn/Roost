//
//  quicksearch-test.swift
//
//  Exercises what the search panel answers besides apps: sums, unit
//  conversions and actions -- and, mostly, what it must leave alone.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Log.swift \
//            Roost/UI/Notice.swift Roost/Launcher/Notify.swift \
//            Roost/Launcher/KeepAwake.swift Roost/Launcher/AudioOutputs.swift \
//            Roost/Launcher/RoostTimers.swift Roost/Launcher/QuickSearch.swift \
//            Tools/quicksearch-test.swift | swift -
//
//  The panel exists to switch apps. Every case under "leaves apps alone"
//  is a query that must produce no extra row, because an extra row above
//  Safari when somebody typed "sa" is a regression in the one thing the
//  panel is for.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}
func calc(_ s: String) -> Double? { QuickSearch.calculate(s) }

print("Sums")
check("12*8+5 = 101", calc("12*8+5") == 101)
check("precedence: 2+3*4 = 14", calc("2+3*4") == 14)
check("brackets: (2+3)*4 = 20", calc("(2+3)*4") == 20)
check("power is right-associative: 2^3^2 = 512", calc("2^3^2") == 512)
check("unary minus: -3+5 = 2", calc("-3+5") == 2)
check("× and ÷ are accepted", calc("6×7") == 42 && calc("84÷2") == 42)
check("decimals", calc("0.1+0.2").map { abs($0 - 0.3) < 1e-12 } ?? false)
check("functions: sqrt(16)+1 = 5", calc("sqrt(16)+1") == 5)
check("pi", calc("2*pi").map { abs($0 - 2 * .pi) < 1e-12 } ?? false)
check("grouping commas are ignored", calc("1,000*2") == 2000)
check("modulo", calc("10%3") == 1)
check("division by zero is not an answer", calc("1/0") == nil)
check("half an expression is not an answer", calc("1+") == nil && calc("(2+3") == nil)
check("a plain number is a query, not a sum", calc("42") == nil && calc("-5") == nil)
check("an unknown function is not an answer", calc("rm(1)") == nil && calc("abc+1") == nil)
check("formatting drops trailing zeros", QuickSearch.format(101) == "101"
      && QuickSearch.format(0.5) == "0.5" && QuickSearch.format(1.0 / 3) == "0.3333333333")
// Found in review, each shown and copied as the answer before.
check("a comma before three digits groups: 1,000*2 = 2000", calc("1,000*2") == 2000)
check("any other comma is a decimal point: 1,5*2 = 3", calc("1,5*2") == 3)
check("3,14*2 = 6.28", calc("3,14*2").map { abs($0 - 6.28) < 1e-12 } ?? false)
check("a sign belongs to the power: -2^2 = -4", calc("-2^2") == -4)
check("but an exponent may be negative: 2^-1 = 0.5", calc("2^-1") == 0.5)
check("(-2)^2 = 4", calc("(-2)^2") == 4)
check("a large answer keeps its whole-number digits",
      QuickSearch.format(1234567890123 + 0.5) == "1234567890123.5")
let deep = String(repeating: "(", count: 30_000) + "1" + String(repeating: ")", count: 30_000) + "+1"
check("thirty thousand brackets are refused, not a crash", calc(deep) == nil)
check("nor as many signs", calc(String(repeating: "-", count: 30_000) + "1+1") == nil)
check("ordinary nesting still works", calc("((((2+3))))*sqrt(sqrt(16))") == 10)

print("\nUnits")
func conv(_ s: String) -> String? { QuickSearch.convert(s) }
check("5 km in miles", conv("5 km in miles") == "3.107 mi")
check("72 f to c", conv("72 f to c") == "22.222°C")
check("2 gb in mb", conv("2 gb in mb") == "2000 MB")
check("10 kg to lb", conv("10 kg to lb") == "22.046 lb")
check("units are case-insensitive", conv("5 KM in Miles") == "3.107 mi")
check("different kinds do not convert", conv("5 km in kg") == nil)
check("an unknown unit does not convert", conv("5 parsecs in km") == nil)
check("a sentence is not a conversion", conv("go to work") == nil)
check("a small result is not rounded to nothing: 1 mm in km", conv("1 mm in km") == "0.000001 km")
check("1 s in hours", conv("1 s in hours")?.hasPrefix("0.000278") == true)

print("\nActions")
check("lock finds Lock Screen", QuickSearch.Action.matching("lock") == [.lockScreen])
check("dark finds Toggle Dark Mode", QuickSearch.Action.matching("dark") == [.toggleDarkMode])
check("trash finds Empty Bin", QuickSearch.Action.matching("trash") == [.emptyBin])
check("sleep finds both sleeps", Set(QuickSearch.Action.matching("sleep")) == [.sleep, .sleepDisplay])
check("awake finds Keep Mac Awake", QuickSearch.Action.matching("awake") == [.keepAwake])
check("caffeinate finds it too", QuickSearch.Action.matching("caffeinate") == [.keepAwake])
check("its title says what choosing it does", QuickSearch.Action.keepAwake.title == "Keep Mac Awake")
check("eject finds Eject All Disks", QuickSearch.Action.matching("eject") == [.ejectAll])

print("\nLeaves apps alone")
for query in ["sa", "sl", "s", "chrome", "safari", "Visual Studio Code", "1Password", "42",
              "Xcode 16", "zoom", "notes", "mail", "terminal", "slack", "docker"] {
    check("\"\(query)\" adds nothing", QuickSearch.results(for: query).isEmpty)
}

print("\nWhat a row says")
check("a sum shows the working and copies the answer",
      QuickSearch.results(for: "12*8+5") == [.answer(title: "12*8+5 = 101", copy: "101")])
check("a conversion copies only the result",
      QuickSearch.results(for: "5 km in miles") == [.answer(title: "5 km in miles = 3.107 mi", copy: "3.107 mi")])

print("\nKeep awake for a while")
let awake = QuickSearch.awakeDuration
check("awake 45m is 45 minutes", awake("awake 45m") == 2_700)
check("awake 2h is two hours", awake("awake 2h") == 7_200)
check("awake 1h30m", awake("awake 1h30m") == 5_400)
check("keep awake for 2 hours", awake("keep awake for 2 hours") == 7_200)
check("keep mac awake 1 hour and 15 minutes", awake("keep mac awake 1 hour and 15 minutes") == 4_500)
check("caffeinate 1.5h", awake("caffeinate 1.5h") == 5_400)
check("awake alone has no time", awake("awake") == nil)
check("a nonsense time is not a time", awake("awake soon") == nil && awake("awake 5x") == nil)
check("zero is not a time", awake("awake 0m") == nil)
check("over a day is refused", awake("awake 200h") == nil)
check("awake alone offers until-off and an hour",
      QuickSearch.results(for: "awake") == [.action(.keepAwake), .keepAwake(for: 3_600)])
check("awake 45m offers exactly that", QuickSearch.results(for: "awake 45m") == [.keepAwake(for: 2_700)])

print("\nEnding a session")
check("restart finds Restart", QuickSearch.Action.matching("restart") == [.restart])
check("reboot finds it too", QuickSearch.Action.matching("reboot") == [.restart])
check("shut finds Shut Down", QuickSearch.Action.matching("shut") == [.shutDown])
check("logout finds Log Out", QuickSearch.Action.matching("logout") == [.logOut])
check("quit all finds Quit All Apps", QuickSearch.Action.matching("quit all") == [.quitAll])
check("three letters are not enough to end a session: log", QuickSearch.Action.matching("log").isEmpty)
check("nor res", QuickSearch.Action.matching("res").isEmpty)
let own = "com.sagar.roost"
check("Quit All quits an ordinary app", QuickSearch.Action.quits(bundleID: "com.apple.Safari", regular: true, own: own))
check("but not Finder", !QuickSearch.Action.quits(bundleID: "com.apple.finder", regular: true, own: own))
check("nor Roost", !QuickSearch.Action.quits(bundleID: own, regular: true, own: own))
check("nor a menu bar utility", !QuickSearch.Action.quits(bundleID: "com.example.menubar", regular: false, own: own))

print("\nSound outputs")
typealias Device = AudioOutputs.Device
let speakers = Device(id: 1, name: "MacBook Air Speakers", transport: .builtIn, isCurrent: true)
let buds = Device(id: 2, name: "Nothing ear (1)", transport: .bluetooth, isCurrent: false)
let pods = Device(id: 3, name: "Amit's AirPods Pro", transport: .bluetooth, isCurrent: false)
let french = Device(id: 4, name: "Écouteurs", transport: .usb, isCurrent: false)
let devices: [Device] = [speakers, buds, pods, french]
let sound = AudioOutputs.matching("sound", in: devices)
check("sound lists every output, above the apps", sound.primary.count == 4 && sound.secondary.isEmpty)
check("the one not playing first, the current one last", sound.primary.last == speakers)
check("sound airpods narrows to the AirPods", AudioOutputs.matching("sound airpods", in: devices).primary == [pods])
check("sound air finds every output with Air in its name",
      Set(AudioOutputs.matching("sound air", in: devices).primary.map(\.id)) == [pods.id, speakers.id])
check("speakers is a keyword too", AudioOutputs.matching("speakers", in: devices).primary.count == 4)
let byName = AudioOutputs.matching("airpods", in: devices)
check("a device's own name finds it, but below the apps", byName.primary.isEmpty && byName.secondary == [pods])
check("mac finds the speakers only below the apps -- it may be Macs Fan Control",
      AudioOutputs.matching("mac", in: devices).secondary == [speakers])
check("accents are folded: ecouteurs", AudioOutputs.matching("ecouteurs", in: devices).secondary == [french])
check("two letters find nothing", AudioOutputs.matching("ai", in: devices) == ([], []))
check("an output row is offered in results", QuickSearch.results(for: "sound ear", outputs: devices) == [.output(buds)])
check("and the name-only ones in trailing", QuickSearch.trailing(for: "nothing", outputs: devices) == [.output(buds)])

print("\nHelp")
let helpRows: [QuickSearch.Result] = QuickSearch.results(for: "?")
check("? lists what the panel can do", helpRows.count >= 10)
check("help does too", QuickSearch.results(for: "help") == helpRows)
check("each line fills the field with its example rather than running",
      helpRows.allSatisfy { $0.fill != nil })
// With an output to find, as any Mac has: "sound" lists the outputs.
let anOutput = [AudioOutputs.Device(id: 1, name: "Speakers", transport: .builtIn, isCurrent: true)]
check("and every example it gives does something",
      helpRows.compactMap(\.fill).allSatisfy { !QuickSearch.results(for: $0, outputs: anOutput).isEmpty })

print("\nTimers")
check("timer 10m is ten minutes, unnamed", QuickSearch.timerRequest("timer 10m")?.seconds == 600
      && QuickSearch.timerRequest("timer 10m")?.label == nil)
check("timer 25 minutes Tea keeps the name as typed", QuickSearch.timerRequest("timer 25 minutes Tea")?.label == "Tea")
check("set a timer for 1h30m to Call Mum",
      QuickSearch.timerRequest("set a timer for 1h30m to Call Mum").map { $0.seconds == 5_400 && $0.label == "Call Mum" } ?? false)
check("timer 90s is in seconds", QuickSearch.timerRequest("timer 90s")?.seconds == 90)
check("timer with no time is not a timer", QuickSearch.timerRequest("timer tea") == nil)
check("a timer row is offered", QuickSearch.results(for: "timer 5m") == [.timer(seconds: 300, label: nil)])
check("timer alone, with none running, offers nothing", QuickSearch.results(for: "timer").isEmpty)

print("\nVolume and mute")
check("vol 30", QuickSearch.volumeLevel("vol 30") == 30)
check("volume 75%", QuickSearch.volumeLevel("volume 75%") == 75)
check("set volume to 0", QuickSearch.volumeLevel("set volume to 0") == 0)
check("over 100 is not a volume", QuickSearch.volumeLevel("vol 150") == nil)
check("a volume row is offered", QuickSearch.results(for: "vol 30") == [.volume(30)])
check("mute offers sound and microphone", Set(QuickSearch.Action.matching("mute")) == [.muteSound, .muteMic])
check("mute mic is just the microphone", QuickSearch.Action.matching("mute mic") == [.muteMic])
check("mic alone is left to Microsoft's apps", QuickSearch.Action.matching("mic").isEmpty
      && QuickSearch.Action.matching("micro").isEmpty)

print("\nColour and speed")
check("color finds the colour picker", QuickSearch.Action.matching("color") == [.pickColor])
check("colour too", QuickSearch.Action.matching("colour") == [.pickColor])
check("col does not -- it may be ColorSync Utility", QuickSearch.Action.matching("col").isEmpty)
check("speed test finds it", QuickSearch.Action.matching("speed test") == [.speedTest])

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
