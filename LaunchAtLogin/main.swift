//
//  main.swift
//  LaunchAtLogin
//
//  The login item helper: a tiny app macOS starts at login, whose only job is
//  to start the app it is embedded in and get out of the way.
//
//  It exists because `SMAppService.loginItem` registers a *bundle*, and the
//  bundle it registers has to be launchable on its own. Roost cannot register
//  itself as a login item and also control when it appears, so the helper is
//  the indirection.
//
import AppKit

guard let identifier = Bundle.main.bundleIdentifier,
      let hostID = LoginHelper.hostBundleID(forHelperID: identifier),
      let host = LoginHelper.hostApp(forHelperAt: Bundle.main.bundleURL)
else {
    // Nothing identifiable to launch. Exiting non-zero so the failure shows
    // up in the login item's own log rather than looking like a clean run
    // that did nothing.
    exit(1)
}

// Already running, because the user opened it before login finished or macOS
// restored it from the previous session. Asking the Workspace to open it a
// second time is not harmful, but it is not free either, and the answer to
// "is Roost running" is already known here.
if !NSRunningApplication.runningApplications(withBundleIdentifier: hostID).isEmpty {
    exit(0)
}

// The wait is not belt-and-braces. `openApplication` is asynchronous, and the
// version of this that shipped before called it from a function and then fell
// off the end of top-level code -- so the process exited while the request was
// still in flight, and whether the app launched came down to whether
// LaunchServices had taken the XPC message yet. It usually had. "Usually" is
// not a launch policy.
//
// The timeout is the other half: a helper that blocks forever at login is
// worse than one that gives up, and the request has been dispatched either
// way by the time it expires.
let finished = DispatchSemaphore(value: 0)
var failure: Error?

let configuration = NSWorkspace.OpenConfiguration()
// Roost is LSUIElement: no Dock icon, and no window at launch. There is
// nothing for activation to bring forward, so asking for it would be asking
// the window server to change focus to nothing.
configuration.activates = false

NSWorkspace.shared.openApplication(at: host, configuration: configuration) { _, error in
    failure = error
    finished.signal()
}

if finished.wait(timeout: .now() + 10) == .timedOut {
    exit(0)
}
exit(failure == nil ? 0 : 1)
