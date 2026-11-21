//
//  keepawake-test.swift
//
//  Keep Mac Awake takes a real power assertion and gives it back.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Log.swift Roost/UI/Notice.swift \
//            Roost/Launcher/Notify.swift Roost/Launcher/KeepAwake.swift \
//            Roost/Launcher/RoostTimers.swift Tools/keepawake-test.swift | swift -
//
//  Checked against `pmset -g assertions`, which is where anybody wondering
//  why their Mac did not sleep would look: an assertion taken and never
//  released is the bug this feature can have, and only macOS's own list can
//  show it. The assertion is held for well under a second.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func listed() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.contains("pid \(getpid())(") && text.contains("Roost: Keep Mac Awake")
}

print("Keep Mac Awake")
let awake = KeepAwake.shared
check("starts off", !awake.isOn && !listed())
check("toggling turns it on", awake.toggle())
check("and macOS lists the assertion", listed())
awake.turnOn()
check("turning on twice holds one assertion, not two", awake.isOn)
check("toggling again turns it off", !awake.toggle())
check("and the assertion is gone", !listed())
awake.turnOff()
check("turning off twice is harmless", !awake.isOn)

print("\nFor a while")
awake.turnOn(for: 1)
check("a timed keep-awake is on", awake.isOn && listed())
check("and knows when it ends", awake.endsAt.map { $0.timeIntervalSinceNow > 0 && $0.timeIntervalSinceNow <= 1 } ?? false)
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
check("and lets the Mac sleep again when the time is up", !awake.isOn && !listed())
check("with no end left behind", awake.endsAt == nil)
awake.turnOn(for: 1)
awake.turnOn()
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
check("turning on without a time cancels the timer", awake.isOn && listed())
awake.turnOff()
check("off is off", !awake.isOn && !listed())

print("\nTimers")
let timers = RoostTimers.shared
var finished: [String?] = []
timers.onFinish = { finished.append($0.label) }
let tea = timers.start(1, label: "tea")
let other = timers.start(1, label: "never")
check("two timers are running", timers.running.count == 2)
check("each says when it ends", RoostTimers.describe(tea).hasPrefix("tea, ends at"))
timers.cancel(other.id)
check("a stopped one is gone at once", timers.running.map(\.label) == ["tea"])
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
check("the other finishes on time", finished == ["tea"])
check("and nothing is left running", timers.running.isEmpty)

print("\nSaying how long")
check("30 seconds is not 0 minutes", !KeepAwake.describe(30).contains("0 minutes") && KeepAwake.describe(30).contains("30"))
check("90 seconds keeps its seconds", KeepAwake.describe(90).contains("30"))
check("an hour is an hour", KeepAwake.describe(3_600).contains("1") && !KeepAwake.describe(3_600).contains("second"))

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
