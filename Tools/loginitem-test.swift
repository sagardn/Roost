//
//  loginitem-test.swift
//
//  Exercises the login item helper's two pieces of arithmetic: finding the app
//  it is embedded in, and deriving that app's bundle identifier from its own.
//
//  Run:  cat LaunchAtLogin/LoginHelper.swift Tools/loginitem-test.swift | swift -
//
//  Both run exactly once, at login, on a machine nobody is looking at, and
//  neither reports anything when it is wrong -- the helper simply launches
//  nothing, or the wrong thing, and the user concludes "launch at login does
//  not work". So they are checked against paths and identifiers written down
//  here rather than against wherever this copy happens to be installed.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

// MARK: - Finding the containing app

print("LoginHelper.hostApp")

do {
    let helper = url("/Applications/Roost.app/Contents/Library/LoginItems/LaunchAtLogin.app")
    check("the app four directories up is the answer",
          LoginHelper.hostApp(forHelperAt: helper)?.path == "/Applications/Roost.app")
}

do {
    // Not every Mac installs to /Applications, and the depth is relative to
    // the helper, not absolute.
    let helper = url("/Users/someone/Desktop/builds/Roost.app/Contents/Library/LoginItems/LaunchAtLogin.app")
    check("it does not care where the app itself lives",
          LoginHelper.hostApp(forHelperAt: helper)?.path
            == "/Users/someone/Desktop/builds/Roost.app")
}

do {
    // A trailing slash is what you get from a URL built by appending
    // components, and it must not count as a directory of its own.
    let helper = url("/Applications/Roost.app/Contents/Library/LoginItems/LaunchAtLogin.app/")
    check("a trailing slash is not a level",
          LoginHelper.hostApp(forHelperAt: helper)?.path == "/Applications/Roost.app")
}

do {
    // The helper copied out of its bundle and run on its own. Four levels up
    // from here is a directory, not an app, and launching whatever sits there
    // is the failure this refusal exists to prevent.
    let loose = url("/Users/someone/Downloads/LaunchAtLogin.app")
    check("a helper outside an app bundle gets no answer",
          LoginHelper.hostApp(forHelperAt: loose) == nil)
}

do {
    // Four levels up lands exactly on the root. "/" is its own parent, so
    // without the walked-off-the-top guard the loop reports / as an app.
    let shallow = url("/a/b/c/LaunchAtLogin.app")
    check("walking off the top of the filesystem is not an app",
          LoginHelper.hostApp(forHelperAt: shallow) == nil)
}

do {
    let deeper = url("/a/b/c/d/e/LaunchAtLogin.app")
    check("a directory that is simply not an app is refused",
          LoginHelper.hostApp(forHelperAt: deeper) == nil)
}

do {
    // The real layout, with the app named something else: the depth is fixed
    // by SMAppService's expectations, not by the app's name.
    let helper = url("/Applications/Something Else.app/Contents/Library/LoginItems/Helper.app")
    check("the app's name is not part of the arithmetic",
          LoginHelper.hostApp(forHelperAt: helper)?.lastPathComponent
            == "Something Else.app")
}

// MARK: - Deriving the app's identifier

print("\nLoginHelper.hostBundleID")

check("the suffix comes off the end",
      LoginHelper.hostBundleID(forHelperID: "com.sagar.roost.LaunchAtLogin")
        == "com.sagar.roost")

check("an identifier without the suffix is not this helper's",
      LoginHelper.hostBundleID(forHelperID: "com.sagar.roost") == nil)

// The reason this is a suffix check and not a replacement: an identifier with
// the suffix in the middle would have its middle cut out, and the result
// would be asked about under a name nothing answers to.
check("the suffix is only removed from the end",
      LoginHelper.hostBundleID(forHelperID: "com.example.LaunchAtLogin.Tool") == nil)

check("a suffix and nothing else is not an identifier",
      LoginHelper.hostBundleID(forHelperID: ".LaunchAtLogin") == nil)

check("nor is an empty string",
      LoginHelper.hostBundleID(forHelperID: "") == nil)

check("the suffix is matched exactly, case and all",
      LoginHelper.hostBundleID(forHelperID: "com.sagar.roost.launchatlogin") == nil)

// MARK: - The two together, on the layout that ships

print("\nThe shipping layout")

do {
    let helper = url("/Applications/Roost.app/Contents/Library/LoginItems/LaunchAtLogin.app")
    let host = LoginHelper.hostApp(forHelperAt: helper)
    let id = LoginHelper.hostBundleID(forHelperID: "com.sagar.roost.LaunchAtLogin")
    check("the path and the identifier describe the same app",
          host?.lastPathComponent == "Roost.app" && id == "com.sagar.roost")
    // PRODUCT_BUNDLE_IDENTIFIER is com.sagar.roost for the app and
    // com.sagar.roost.LaunchAtLogin for this target. If either moves, this is
    // the check that notices.
    check("and the suffix is the one the project actually sets",
          LoginHelper.identifierSuffix == ".LaunchAtLogin")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
