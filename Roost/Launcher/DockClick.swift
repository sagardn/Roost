import AppKit
import ApplicationServices

/// Click an app in the **Dock** to bring it up; click it again to put it
/// away.
///
/// macOS does not do the second half. Clicking the Dock icon of the app you
/// are already in does nothing at all -- which is the one case this adds,
/// and the reason the whole thing can be done without touching the Dock's
/// own behaviour. Nothing is intercepted and no event is swallowed: Roost
/// listens, and acts only in the case macOS leaves empty. A click on a
/// different app, or on one that is not running, is the Dock's to handle and
/// is left to it.
///
/// Reading the Dock is ordinary Accessibility. Each item is an
/// `AXApplicationDockItem` carrying `AXURL` (the bundle on disk), `AXFrame`
/// and `AXIsApplicationRunning`, which is everything needed to say what was
/// clicked.
enum DockClick {

    struct Item: Equatable {
        let bundleID: String
        let frame: CGRect
        let isRunning: Bool
    }

    // MARK: - The decision, which is pure

    /// The item under a point, or nil.
    ///
    /// Frames come from the Dock itself, so magnification, autohide, and the
    /// Dock being on the left or the right are all already accounted for --
    /// there is no geometry of our own to get wrong.
    static func hit(_ point: CGPoint, in items: [Item]) -> Item? {
        items.first { $0.frame.contains(point) }
    }

    /// How long an app must already have been in front for a click on its
    /// icon to mean "put it away".
    ///
    /// The whole difficulty is telling a click that *raised* an app from a
    /// click on an app that was already there. Reading "who is frontmost"
    /// inside the mouse-down callback cannot do it: whether the Dock
    /// activates on the press or the release is its business, not a contract,
    /// and a click that had just raised the app looked identical to a click
    /// on an app that had been in front all along -- which is a single click
    /// that puts an app away when the person meant to bring it up.
    ///
    /// So the question asked is not "is it frontmost" but "has it been
    /// frontmost since before this click began". A click that caused the
    /// activation can never satisfy that, whichever event the Dock acts on.
    /// It also rules out the second of two quick clicks on the same icon.
    static let settledBefore: TimeInterval = 0.3

    /// Which app to put away, or nil to leave the click to the Dock.
    ///
    /// Only one case is ours: the click landed on a running app that had
    /// settled in front *before* the mouse went down, and is still in front
    /// now. Everything else -- launching, raising, restoring -- the Dock has
    /// just done, and doing it again would fight it.
    ///
    /// `activatedAt` is when that app last came to the front, from the
    /// workspace's own notification. nil means it has been in front since
    /// before Roost was watching, which is as settled as it gets.
    static func appToPutAway(hit: Item?,
                             frontmostAtPress: String?,
                             frontmostNow: String?,
                             hadWindowOnScreen: Bool = true,
                             pressedAt: Date = Date(),
                             activatedAt: Date? = nil) -> String? {
        guard let hit, hit.isRunning else { return nil }
        guard hit.bundleID == frontmostAtPress, hit.bundleID == frontmostNow else { return nil }
        // There has to have been something on screen to put away. Minimising
        // an app does not deactivate it, so an app whose windows are all
        // down is usually still the frontmost one -- and the click that
        // brings it back therefore looked exactly like a click on an app
        // sitting in front of you. That is a window restored and minimised
        // again in the same gesture, which is what was reported.
        guard hadWindowOnScreen else { return nil }
        if let activatedAt, pressedAt.timeIntervalSince(activatedAt) < settledBefore {
            return nil
        }
        return hit.bundleID
    }

    /// Whether this app has a normal window on screen right now.
    ///
    /// The window server's own list, which omits minimised windows -- that
    /// is the whole reason it is used. Layer 0 only, so a floating panel or
    /// a status item does not count as "a window you can see".
    ///
    /// Measured at 0.68 ms, and asked only when a click lands on a Dock
    /// icon. The Accessibility route would have been the same answer for
    /// several times the cost.
    static func hasWindowOnScreen(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                                     .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// Whether a press and a release are the same click on the same item.
    ///
    /// A drag that starts on one icon and ends on another is somebody
    /// rearranging their Dock, not clicking it.
    static func isSameClick(press: Item?, release: Item?) -> Bool {
        guard let press, let release else { return false }
        return press.bundleID == release.bundleID
    }

    /// The rectangle the Dock occupies, grown to cover magnification.
    ///
    /// A pre-filter, not a hit test: it is cached and therefore allowed to
    /// be slightly stale, which is why it is generous. Being wrong costs one
    /// unnecessary read of the Dock; being too tight would miss a real
    /// click, so it errs outward.
    static func region(of items: [Item]) -> CGRect? {
        guard var union = items.first?.frame else { return nil }
        for item in items.dropFirst() { union = union.union(item.frame) }
        // Magnified icons grow well past their resting frame, and the Dock
        // slides as items are added.
        return union.insetBy(dx: -union.width, dy: -union.height)
    }

    // MARK: - Reading the Dock

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    /// Every application item in the Dock, with its frame on screen.
    ///
    /// Read fresh rather than cached: the Dock magnifies under the pointer,
    /// hides, and is rearranged, so a frame from a moment ago can be the
    /// wrong one.
    ///
    /// Measured on this Mac, 18 items: **59.95 ms for the first read** and
    /// **2.21 ms after**. Both numbers shape how this is used. The first is
    /// the Accessibility connection warming up, so it is paid once at
    /// launch, off the main thread, rather than on somebody's first click.
    /// The second is small but not free, and this used to run on every left
    /// click anywhere on screen -- hence `region`, which answers "could that
    /// click have been in the Dock at all" from a cached rectangle.
    static func items() -> [Item] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        // Reading another process's Accessibility tree waits on that process,
        // with no limit unless one is set, and the Dock is not immune to
        // being busy. Bounded here rather than through WindowControl's
        // helper so this file keeps compiling on its own, which is what its
        // test suite does.
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let lists = value(application, kAXChildrenAttribute as String) as? [AXUIElement],
              let list = lists.first,
              let elements = value(list, kAXChildrenAttribute as String) as? [AXUIElement]
        else { return [] }

        return elements.compactMap { element in
            guard value(element, kAXSubroleAttribute as String) as? String
                    == "AXApplicationDockItem",
                  let url = value(element, "AXURL") as? URL,
                  let bundleID = Bundle(url: url)?.bundleIdentifier,
                  let frame = frame(of: element)
            else { return nil }
            let running = value(element, "AXIsApplicationRunning") as? Bool ?? false
            return Item(bundleID: bundleID, frame: frame, isRunning: running)
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let raw = value(element, kAXPositionAttribute as String),
              let sizeRaw = value(element, kAXSizeAttribute as String)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        // CFGetTypeID before the cast, because an attribute that is present
        // is not guaranteed to be an AXValue.
        guard CFGetTypeID(raw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
