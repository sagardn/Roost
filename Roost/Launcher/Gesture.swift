import AppKit
import IOKit.hid

/// A trackpad tap gesture opens the search: a three-finger double tap by
/// default, four fingers if you prefer.
///
/// macOS has no public API for custom trackpad gestures -- the public
/// NSEvent gesture events only arrive for the frontmost app's own views, and
/// the system owns the three and four finger swipes. The only route to a
/// global gesture is MultitouchSupport, a private framework. That is what
/// BetterTouchTool and friends use.
///
/// Consequences, deliberately accepted:
///   - private API: undocumented, and Apple can change or remove it
///   - cannot be shipped through the Mac App Store
///   - macOS may require Input Monitoring permission to see raw touches
///
/// To keep the risk small this reads *only* the finger count that the
/// callback is handed. It never parses the MTTouch struct, whose layout has
/// changed between macOS releases and is the usual reason this kind of code
/// breaks.
final class Gesture {
    static let shared = Gesture()

    /// Set before start(). Called on the main queue.
    var onTap: (() -> Void)?

    private var handle: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var running = false

    private typealias ContactCallback =
        @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterCallback =
        @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

    // The C callback cannot capture context, so the recogniser is a static.
    fileprivate static let recognizer = TapRecognizer()

    private init() {}

    var isAvailable: Bool {
        FileManager.default.fileExists(
            atPath: "/System/Library/PrivateFrameworks/MultitouchSupport.framework")
    }

    /// Whether macOS has granted Input Monitoring.
    ///
    /// Informational only, and deliberately not a precondition for starting.
    /// Measured on macOS 27 with the grant explicitly *denied*: MTDeviceStart
    /// still delivered 459 contact frames in six seconds, and no dialog
    /// appeared. Reading the finger count out of MultitouchSupport is not an
    /// event tap, so it is not what Input Monitoring governs -- gating the
    /// gesture on this grant, as a first attempt at the login-prompt bug did,
    /// turns a working feature off for everyone who never granted a permission
    /// the feature does not use.
    var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    func start(fingers: Set<Int> = [2, 3], taps: Int = 2) -> Bool {
        Gesture.recognizer.configure(fingers: fingers, taps: taps)
        // Already listening: the new counts are enough, no need to restart.
        guard !running else { return true }

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            NSLog("Roost: MultitouchSupport unavailable: \(String(cString: dlerror()))")
            return false
        }
        self.handle = handle

        guard let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            NSLog("Roost: MultitouchSupport symbols missing")
            return false
        }

        let createList = unsafeBitCast(createSym, to: CreateList.self)
        let register = unsafeBitCast(registerSym, to: RegisterCallback.self)
        let deviceStart = unsafeBitCast(startSym, to: DeviceStart.self)

        guard let list = createList()?.takeRetainedValue() as? [AnyObject], !list.isEmpty else {
            NSLog("Roost: no multitouch devices")
            return false
        }

        for entry in list {
            let device = Unmanaged.passUnretained(entry).toOpaque()
            register(device, gestureContactCallback)
            deviceStart(device, 0)
            devices.append(device)
        }
        running = true
        return true
    }

    func stop() {
        guard running, let handle, let stopSym = dlsym(handle, "MTDeviceStop") else { return }
        let deviceStop = unsafeBitCast(stopSym, to: DeviceStop.self)
        devices.forEach { deviceStop($0) }
        devices.removeAll()
        running = false
    }

    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in self?.onTap?() }
    }
}

/// Recognises a multi-finger double tap from a stream of finger counts.
///
/// Pulled out of the C callback so it can be exercised without a trackpad: a
/// double-tap recogniser is a small state machine with several ways to be
/// subtly wrong, and "it felt right when I tried it" is not a test. See
/// Tools/gesture-test.swift.
final class TapRecognizer {
    /// Which finger counts count as a tap. A set rather than one number so
    /// three- and four-finger double taps can both open the search without
    /// the user having to pick one -- whichever is comfortable on the day.
    ///
    /// Two is never accepted, here or in Prefs. macOS makes a two-finger tap
    /// a secondary click and the double tap Smart Zoom, and this layer can
    /// only observe touches, so every search also fired a right-click and a
    /// zoom. The fallback below is [3] for the same reason: an empty set must
    /// not quietly reintroduce it.
    private(set) var acceptedFingers: Set<Int> = [3]
    private(set) var requiredTaps = 2

    /// Tight on purpose. Multi-finger *swipes* drive Mission Control and space
    /// switching, and this only sees finger counts, not movement -- so
    /// duration is the discriminator. A tap is well under this; a swipe keeps
    /// fingers down far longer.
    let maxTapDuration = 0.25
    /// How long a second tap has to arrive to count as a double tap.
    let doubleTapWindow = 0.45

    private var fingersDown = 0
    private var peak = 0
    private var startedAt: Double = 0
    private var tapCount = 0
    private var lastTapAt: Double = 0
    /// The finger count of the run in progress. A three-finger tap followed
    /// by a four-finger tap is two different gestures, not a double tap, even
    /// when both counts are accepted.
    private var runFingers = 0

    func configure(fingers: Set<Int>, taps: Int) {
        // Filtered here as well as in Prefs, so no caller can reintroduce the
        // two-finger tap -- a lower bound rather than a fixed set, which
        // leaves five fingers possible if a trackpad ever reports one.
        let allowed = fingers.filter { $0 >= 3 }
        acceptedFingers = allowed.isEmpty ? [3] : allowed
        requiredTaps = max(1, taps)
        tapCount = 0
        runFingers = 0
    }

    /// Feed one contact frame. True when the gesture just completed.
    func frame(fingers count: Int, at timestamp: Double) -> Bool {
        var fired = false

        if count > fingersDown {
            if fingersDown == 0 { startedAt = timestamp }
            peak = max(peak, count)
        }

        if count == 0 && fingersDown > 0 {
            let quick = (timestamp - startedAt) < maxTapDuration
            if quick && acceptedFingers.contains(peak) {
                // a tap landed; see whether it completes the required run
                if timestamp - lastTapAt > doubleTapWindow || peak != runFingers {
                    tapCount = 0
                }
                runFingers = peak
                tapCount += 1
                lastTapAt = timestamp
                if tapCount >= requiredTaps {
                    tapCount = 0
                    fired = true
                }
            } else {
                tapCount = 0
            }
            peak = 0
        }

        fingersDown = count
        return fired
    }
}

/// Top-level so it can be a C function pointer.
///
/// Only `fingers` is used; the touch buffer is never dereferenced.
private func gestureContactCallback(device: Int32,
                                    data: UnsafeMutableRawPointer?,
                                    fingers: Int32,
                                    timestamp: Double,
                                    frame: Int32) -> Int32 {
    if Gesture.recognizer.frame(fingers: Int(fingers), at: timestamp) {
        Gesture.shared.fire()
    }
    return 0
}
