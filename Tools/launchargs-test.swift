//
//  launchargs-test.swift
//
//  Exercises the startup argument parser.
//
//  Run:  cat Roost/Startup/LaunchArguments.swift \
//            Tools/launchargs-test.swift | swift -
//
//  Two of these arguments change state the moment they are seen -- --reset
//  wipes the settings store, and the login item pair rewrites a registration
//  that only the registered bundle can repair. A parser that misreads a
//  malformed command line does that to somebody who typed a flag wrong, so
//  the malformed shapes are checked here rather than discovered.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// argv always starts with the executable path.
func parse(_ args: String...) -> LaunchArguments {
    LaunchArguments.parse(["/Applications/Roost.app/Contents/MacOS/Roost"] + args)
}

// MARK: - Nothing

print("LaunchArguments.parse")

do {
    let none = parse()
    check("a bare launch asks for nothing", none == LaunchArguments())
    check("and in particular does not reset the settings store", !none.reset)
}

// MARK: - Flags

check("--reset is seen", parse("--reset").reset)
check("--register-login-item is seen", parse("--register-login-item").registerLoginItem)
check("--unregister-login-item is seen", parse("--unregister-login-item").unregisterLoginItem)

// The two login item flags are not exclusive in the parser. Both on one line
// is a contradiction, but it is the caller's to resolve -- the parser
// reporting what was asked for is what lets the caller say so.
do {
    let both = parse("--register-login-item", "--unregister-login-item")
    check("both login item flags are reported, not silently merged",
          both.registerLoginItem && both.unregisterLoginItem)
}

// Order must not matter, and one flag must not shadow another.
do {
    let many = parse("--reset", "--disable", "cpu", "--register-login-item")
    check("flags are independent of order",
          many.reset && many.registerLoginItem && many.disabledModules == ["cpu"])
}

check("an argument that is not ours is ignored", parse("--nonsense").reset == false)

// MARK: - The module list

print("\n--disable")

check("one module", parse("--disable", "CPU").disabledModules == ["cpu"])
check("several, comma separated",
      parse("--disable", "CPU,RAM,Disk").disabledModules == ["cpu", "ram", "disk"])
check("lower-cased once, at parse time",
      parse("--disable", "CpU").disabledModules == ["cpu"])
check("whitespace around a name is tolerated",
      parse("--disable", "CPU, RAM").disabledModules == ["cpu", "ram"])
check("an empty entry is not a module",
      parse("--disable", "CPU,,RAM").disabledModules == ["cpu", "ram"])
check("nor is a list of nothing but separators",
      parse("--disable", ",,,").disabledModules == [])

// The shapes a typo takes. Neither may consume the argument after it.
check("--disable with nothing after it disables nothing",
      parse("--disable").disabledModules == [])
do {
    let typo = parse("--disable", "--reset")
    check("--disable followed by a flag does not eat the flag", typo.reset)
    check("and does not treat the flag as a module name",
          typo.disabledModules == [])
}

// MARK: - The diagnostic arguments

print("\n--popup")

check("a module name, with the default wait",
      parse("--popup", "CPU").popup
        == LaunchArguments.PopupRequest(name: "CPU", delay: 6))
check("an explicit wait",
      parse("--popup", "CPU", "2").popup
        == LaunchArguments.PopupRequest(name: "CPU", delay: 2))
check("a fractional wait", parse("--popup", "CPU", "0.5").popup?.delay == 0.5)

// The seconds are optional, so whatever follows the name is only a delay if
// it is a number. Neither of these may be eaten as one.
check("a following flag is not a wait",
      parse("--popup", "CPU", "--reset").popup?.delay == 6)
check("and the following flag still takes effect",
      parse("--popup", "CPU", "--reset").reset)
check("a following non-number is not a wait",
      parse("--popup", "CPU", "later").popup?.delay == 6)

check("--popup with nothing after it asks for nothing",
      parse("--popup").popup == nil)
check("--popup followed by a flag asks for nothing",
      parse("--popup", "--reset").popup == nil)
check("no --popup at all", parse().popup == nil)

print("\n--menu-bar")

check("one step", parse("--menu-bar", "row").menuBarSteps == ["row"])
check("several, in order",
      parse("--menu-bar", "combined,row,details").menuBarSteps
        == ["combined", "row", "details"])
check("lower-cased", parse("--menu-bar", "Combined,ROW").menuBarSteps == ["combined", "row"])
check("whitespace trimmed", parse("--menu-bar", "combined, row").menuBarSteps
        == ["combined", "row"])
check("empty steps dropped", parse("--menu-bar", "row,,details").menuBarSteps
        == ["row", "details"])
// A step's own payload may contain a colon and an equals sign; only commas
// separate steps, which is why shapes: uses + for its own list.
check("a step keeps its payload",
      parse("--menu-bar", "shapes:CPU=mini+line_chart").menuBarSteps
        == ["shapes:cpu=mini+line_chart"])
check("--menu-bar with nothing after it", parse("--menu-bar").menuBarSteps == [])

print("\n--render")

check("a subject and a path",
      parse("--render", "settings:CPU", "/tmp/a.png").render
        == LaunchArguments.RenderRequest(subject: "settings:CPU", path: "/tmp/a.png"))
check("a setup page", parse("--render", "setup:2", "/tmp/b.png").render?.subject == "setup:2")

// Neither value has a default. Rendering to a path nobody asked for would
// write a file somewhere unexpected, so a missing path means no render at all.
check("a subject with no path renders nothing",
      parse("--render", "settings:CPU").render == nil)
check("a path that is a flag renders nothing",
      parse("--render", "settings:CPU", "--reset").render == nil)
check("and that flag still takes effect",
      parse("--render", "settings:CPU", "--reset").reset)
check("--render with nothing after it", parse("--render").render == nil)

print("\nAll three together")

do {
    let all = parse("--disable", "gpu", "--popup", "CPU", "3",
                    "--menu-bar", "combined,row", "--render", "setup:0", "/tmp/c.png")
    check("each argument is read independently",
          all.disabledModules == ["gpu"]
            && all.popup == LaunchArguments.PopupRequest(name: "CPU", delay: 3)
            && all.menuBarSteps == ["combined", "row"]
            && all.render == LaunchArguments.RenderRequest(subject: "setup:0",
                                                           path: "/tmp/c.png"))
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
