import AppKit
import ApplicationServices

/// Snaps the frontmost window to a half, a quarter, the whole screen or the
/// next display, from the keyboard.
///
/// The shortcuts are Rectangle's, deliberately: ⌃⌥ plus an arrow is what
/// anyone who has used a Mac window manager already has in their fingers,
/// and a second set to learn is a reason not to switch. The cost is that
/// Rectangle, when installed, already owns them -- so a key Roost cannot
/// register is reported once rather than silently not working.
///
/// The geometry is `Snap`; this file is only the Accessibility calls that
/// read a window's frame and set a new one.
final class WindowSnapper {

    static let shared = WindowSnapper()

    struct Binding {
        let action: Snap.Action
        let keyCode: UInt32
        let modifiers: Hotkey.Modifiers
        let label: String
    }

    static let bindings: [Binding] = {
        let co: Hotkey.Modifiers = [.control, .option]
        let coc: Hotkey.Modifiers = [.control, .option, .command]
        return [
            Binding(action: .leftHalf, keyCode: 123, modifiers: co, label: "⌃⌥←"),
            Binding(action: .rightHalf, keyCode: 124, modifiers: co, label: "⌃⌥→"),
            Binding(action: .topHalf, keyCode: 126, modifiers: co, label: "⌃⌥↑"),
            Binding(action: .bottomHalf, keyCode: 125, modifiers: co, label: "⌃⌥↓"),
            Binding(action: .topLeft, keyCode: 32, modifiers: co, label: "⌃⌥U"),
            Binding(action: .topRight, keyCode: 34, modifiers: co, label: "⌃⌥I"),
            Binding(action: .bottomLeft, keyCode: 38, modifiers: co, label: "⌃⌥J"),
            Binding(action: .bottomRight, keyCode: 40, modifiers: co, label: "⌃⌥K"),
            Binding(action: .maximize, keyCode: 36, modifiers: co, label: "⌃⌥↩"),
            Binding(action: .center, keyCode: 8, modifiers: co, label: "⌃⌥C"),
            Binding(action: .restore, keyCode: 51, modifiers: co, label: "⌃⌥⌫"),
            Binding(action: .previousDisplay, keyCode: 123, modifiers: coc, label: "⌃⌥⌘←"),
            Binding(action: .nextDisplay, keyCode: 124, modifiers: coc, label: "⌃⌥⌘→")
        ]
    }()

    private var hotkeys: [Hotkey] = []
    /// Each window's frame before Roost first moved it, for ⌃⌥⌫. Keyed by
    /// process and the Accessibility element's hash, which is stable for
    /// one window for as long as it exists.
    private var before: [String: CGRect] = [:]

    // MARK: Registration

    /// Registers every binding, and returns the labels another app already
    /// holds.
    @discardableResult
    func start() -> [String] {
        stop()
        var taken: [String] = []
        for binding in Self.bindings {
            if let hotkey = Hotkey(keyCode: binding.keyCode, modifiers: binding.modifiers,
                                   action: { [weak self] in self?.perform(binding.action) }) {
                hotkeys.append(hotkey)
            } else {
                taken.append(binding.label)
            }
        }
        return taken
    }

    func stop() { hotkeys.removeAll() }

    /// Starts, and says so once if some keys were taken. Retried after a
    /// moment first, for the same reason the launcher's own keys are: during
    /// an update the copy being replaced still holds them for a second.
    func startAndReport() {
        guard !start().isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let taken = self.start()
            guard !taken.isEmpty else { return }
            if taken.count == Self.bindings.count {
                Notify.show(localized("Window snapping keys are in use by another app"),
                            symbol: "rectangle.split.2x1", for: 4)
            } else {
                Notify.show(localized("Some window-snapping keys are used by another app: %0", taken.joined(separator: " ")),
                            symbol: "rectangle.split.2x1", for: 4)
            }
        }
    }

    // MARK: Moving

    func perform(_ action: Snap.Action) {
        guard WindowControl.ensureTrusted(for: localized("Window snapping")) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let axApp = WindowControl.appElement(app.processIdentifier)
        guard let window = Self.element(Self.attribute(axApp, kAXFocusedWindowAttribute))
        else { return }

        if (Self.attribute(window, "AXFullScreen") as? Bool) == true {
            Notify.show("A full-screen window can't be snapped", symbol: "rectangle.split.2x1", for: 2)
            return
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let axFrame = Self.frame(of: window) else { return }
        let current = Snap.appKit(fromAX: axFrame, primaryHeight: primaryHeight)
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let index = Snap.screenIndex(for: current, among: screens) else { return }

        let key = "\(app.processIdentifier)-\(CFHash(window))"
        let target: CGRect?
        switch action {
        case .restore:
            target = before.removeValue(forKey: key)
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return }
            let step = action == .nextDisplay ? 1 : screens.count - 1
            target = Snap.move(current, from: screens[index], to: screens[(index + step) % screens.count])
        default:
            target = Snap.frame(for: action, in: screens[index], current: current)
        }
        guard let target else { return }
        if action != .restore, before[key] == nil { before[key] = current }

        Self.setFrame(window, Snap.ax(fromAppKit: target, primaryHeight: primaryHeight), app: axApp)
    }

    // MARK: Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again.
    ///
    /// Moving to another display can be refused when the window's current
    /// size does not fit there, and resizing can be refused when the window
    /// is still where the new size would push it off-screen. Doing size
    /// around position lets whichever was refused land on the second try.
    ///
    /// Apps that have VoiceOver's "enhanced user interface" switched on
    /// animate every frame change and drop intermediate ones, so it is off
    /// for the move and put back afterwards.
    private static func setFrame(_ window: AXUIElement, _ frame: CGRect, app: AXUIElement) {
        let enhanced = "AXEnhancedUserInterface" as CFString
        var wasEnhanced: CFTypeRef?
        AXUIElementCopyAttributeValue(app, enhanced, &wasEnhanced)
        let enhancedOn = (wasEnhanced as? Bool) == true
        if enhancedOn { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }
        defer { if enhancedOn { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) } }

        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let dimensions = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    }
}
