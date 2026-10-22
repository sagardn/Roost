import AppKit

/// Watches for a click on the Dock and puts the app away if it was already
/// in front.
///
/// The tap is **listen-only**. It cannot alter, delay or swallow an event,
/// which is the point: the Dock goes on doing exactly what it did before,
/// and Roost acts afterwards in the one case macOS leaves empty. A filtering
/// tap could have done this more directly and would have put Roost in the
/// path of every click on the machine, where a bug of ours becomes a mouse
/// that does not work.
///
/// Nothing is recorded. The callback reads a location, asks `DockClick`
/// about it, and keeps one bundle identifier between the press and the
/// release.
final class DockWatcher {

    static let shared = DockWatcher()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// What was under the pointer when the button went down, and who was in
    /// front at that moment -- both have to be read before the Dock acts.
    private var pressedItem: DockClick.Item?
    private var frontmostAtPress: String?

    /// Where the Dock roughly is, so a click somewhere else costs nothing.
    /// Reading the Dock properly is 2.21 ms, and this callback runs on every
    /// left click on the machine; a tap whose callback is slow is one macOS
    /// switches off.
    private var region: CGRect?
    private var regionReadAt = Date.distantPast

    /// When the frontmost app last changed, and to what. Tracked from the
    /// workspace's notification rather than read inside the tap, because a
    /// click that has just raised an app is indistinguishable, at that
    /// moment, from a click on an app that was already in front.
    private var activatedBundle: String?
    private var activatedAt: Date?
    private var pressedAt = Date.distantPast
    /// Whether the clicked app had anything on screen when the button went
    /// down. Read then, because the Dock may be about to restore a window.
    private var hadWindowAtPress = false

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.activatedBundle = app?.bundleIdentifier
            self?.activatedAt = Date()
        }
        // `start()` returns quietly while Roost is not trusted, which is how
        // every first launch and every launch after an update begins -- and
        // nothing called it again once the grant arrived, so the switch in
        // Settings read on while the Dock click did nothing until a relaunch.
        // macOS posts this whenever the Accessibility list changes; the
        // trust it reports lags the notification by a moment.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
        }
    }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil, Prefs.dockClickPutsAway, AXIsProcessTrusted() else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                // macOS switches a tap off when a callback runs long -- and
                // this one does Accessibility reads near the Dock -- or on
                // secure input. It says so with these two event types and
                // then stays off: the Dock click went dead until a relaunch,
                // while `isRunning` still said yes and `refresh()` believed it.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = DockWatcher.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                DockWatcher.shared.handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil)
        else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source

        // The first Accessibility read costs 59.95 ms as the connection
        // warms up. Paid here, on a background queue, rather than inside the
        // callback on somebody's first click.
        DispatchQueue.global(qos: .utility).async {
            let items = DockClick.items()
            DispatchQueue.main.async {
                self.region = DockClick.region(of: items)
                self.regionReadAt = Date()
            }
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        pressedItem = nil
        frontmostAtPress = nil
    }

    /// Re-reads the setting: called when the switch in Settings moves.
    func refresh() {
        Prefs.dockClickPutsAway ? start() : stop()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .leftMouseDown:
            // Cheap first: almost every click on the machine is nowhere near
            // the Dock, and those must cost a rectangle test and nothing
            // more.
            if let region, region.contains(event.location) == false,
               Date().timeIntervalSince(regionReadAt) < 5 {
                pressedItem = nil
                frontmostAtPress = nil
                return
            }
            // The Dock is read on the press, before the click has had any
            // effect, because the answer to "was this app already in front"
            // stops being available the moment it is raised.
            let items = DockClick.items()
            region = DockClick.region(of: items)
            regionReadAt = Date()
            pressedItem = DockClick.hit(event.location, in: items)
            pressedAt = Date()
            hadWindowAtPress = pressedItem.flatMap { item in
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: item.bundleID).first
                    .map { DockClick.hasWindowOnScreen(pid: $0.processIdentifier) }
            } ?? false
            frontmostAtPress = pressedItem == nil
                ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        case .leftMouseUp:
            let press = pressedItem
            let atPress = frontmostAtPress
            let at = pressedAt
            // Only this app's own activation time matters; another app
            // coming forward says nothing about how settled this one was.
            let settled = activatedBundle == press?.bundleID ? activatedAt : nil
            let hadWindow = hadWindowAtPress
            pressedItem = nil
            frontmostAtPress = nil
            guard press != nil else { return }

            let release = DockClick.hit(event.location, in: DockClick.items())
            guard DockClick.isSameClick(press: press, release: release) else { return }

            // After the Dock has acted, not before: on mouse-up it may be
            // about to raise the app, and a raise is not a put-away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                guard let bundleID = DockClick.appToPutAway(hit: press,
                                                            frontmostAtPress: atPress,
                                                            frontmostNow: now,
                                                            hadWindowOnScreen: hadWindow,
                                                            pressedAt: at,
                                                            activatedAt: settled)
                else { return }
                // The same decision the launcher's own click makes, so full
                // screen, windows that refuse to minimise and apps with no
                // window all behave identically wherever the click came from.
                WindowControl.toggle(AppEntry(name: bundleID, bundleID: bundleID),
                                     activeApp: bundleID)
            }

        default:
            break
        }
    }
}
