//
//  processcontrol-test.swift
//
//  Exercises what the top-processes list is allowed to kill, and what a
//  kill(2) result means.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Monitor/ProcessControl.swift \
//            Tools/processcontrol-test.swift | swift -
//
//  A force quit takes a process down without letting it save. The two ways
//  this can be wrong are both silent: reporting success for something that
//  did not happen, and sending a signal to a pid that does not mean what the
//  row said. kill(2) reads 0, -1 and any negative number as whole classes of
//  process rather than one, so the guard on those is the difference between
//  ending Chrome and ending the session.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: - Which pids may be signalled at all

print("ProcessControl.isSignallable")

check("an ordinary pid is fine", ProcessControl.isSignallable(4321))
check("and a low one that is still a real process", ProcessControl.isSignallable(2))

// kill(pid, sig) with pid 0 signals every process in the caller's group, -1
// signals everything the caller may signal, and any negative pid signals a
// process group. None of those is a row in a list.
check("0 is every process in our group, not one", !ProcessControl.isSignallable(0))
check("-1 is everything we are allowed to signal", !ProcessControl.isSignallable(-1))
check("a negative pid is a process group", !ProcessControl.isSignallable(-4321))
// launchd. Signalling it is not survivable and it cannot be what a row means.
check("pid 1 is launchd", !ProcessControl.isSignallable(1))

check("an unsignallable pid is refused rather than attempted",
      ProcessControl.forceQuit(pid: 0) == .failed(code: EINVAL))
check("and so is pid 1", ProcessControl.forceQuit(pid: 1) == .failed(code: EINVAL))
// The gentle one is guarded identically. SIGTERM to pid 0 reaches every
// process in the group just as SIGKILL does; being polite about it does not
// make the target narrower.
check("quit refuses pid 0 as well",
      ProcessControl.quit(pid: 0) == .failed(code: EINVAL))
check("and pid 1", ProcessControl.quit(pid: 1) == .failed(code: EINVAL))
check("and a process group",
      ProcessControl.quit(pid: -4321) == .failed(code: EINVAL))

// MARK: - Reading kill(2)

print("\nProcessControl.outcome")

check("zero is success", ProcessControl.outcome(result: 0, errno: 0) == .terminated)
// The list is a sample a second or two old, so a process that exited between
// the sample and the click is ordinary, not a failure worth a warning.
check("ESRCH means it had already gone",
      ProcessControl.outcome(result: -1, errno: ESRCH) == .alreadyGone)
check("EPERM means another user's process",
      ProcessControl.outcome(result: -1, errno: EPERM) == .notPermitted)
check("anything else is carried with its code",
      ProcessControl.outcome(result: -1, errno: EINVAL) == .failed(code: EINVAL))
// errno is only meaningful when the call actually failed.
check("a success is a success whatever errno holds",
      ProcessControl.outcome(result: 0, errno: EPERM) == .terminated)

// MARK: - What is said about it

print("\nProcessControl.message")

check("a termination says nothing -- the row simply goes",
      ProcessControl.message(for: .terminated, name: "Chrome") == nil)
check("every other outcome says something",
      [.alreadyGone, .notPermitted, .failed(code: EINVAL)].allSatisfy {
          ProcessControl.message(for: $0, name: "Chrome") != nil
      })
check("and names the process",
      [.alreadyGone, .notPermitted, .failed(code: EINVAL)].allSatisfy {
          ProcessControl.message(for: $0, name: "Chrome")?.contains("Chrome") == true
      })

// MARK: - Against a real process

print("\nAgainst a process that exists")

do {
    // Our own pid is signallable and definitely alive, so this exercises the
    // live path without ending anything: signal 0 is the existence check.
    let me = ProcessInfo.processInfo.processIdentifier
    check("this test's own pid is signallable", ProcessControl.isSignallable(me))
    check("and kill(pid, 0) finds it", kill(me, 0) == 0)

    // A pid that cannot be running: above the system maximum.
    let absent: Int32 = 99_999
    if kill(absent, 0) != 0 && errno == ESRCH {
        check("a pid nothing owns reports it had already gone",
              ProcessControl.forceQuit(pid: absent) == .alreadyGone)
    } else {
        check("pid \(absent) is in use on this machine, skipping", true)
    }
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
