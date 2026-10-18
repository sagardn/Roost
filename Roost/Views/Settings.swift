import AppKit
import SwiftUI

/// The settings window.
///
/// A frame, a hosting controller and a lookup. The sidebar, the search field,
/// the selection and the keyboard navigation all belong to
/// `SettingsShellView`; this owns the window itself and the one thing SwiftUI
/// cannot do here, which is resolve a name to an AppKit view that a module
/// built.
final class SettingsWindow: NSWindow, NSWindowDelegate {

    private static let initialSize = CGSize(width: 720, height: 480)
    private static let frameAutosaveKey = "com.sagar.roost.Settings.WindowFrame"

    var onClose: (() -> Void)?

    private let model = SettingsModel()

    /// Its cards open pages and switch modules on through the sidebar's own
    /// two paths, so a card and the sidebar can never do it differently.
    private lazy var dashboard = DashboardPane(
        open: { [weak self] name in self?.model.select(name) },
        enable: { [weak self] name in self?.model.setEnabled(name, true) })
    private lazy var cleanup = CleanupPane(width: SettingsMetrics.width)
    /// In a scroll view, as the module pages are: its rows ran off the
    /// bottom of a short window with nothing to say there were more.
    private lazy var cleanupPage = ScrollingPage(cleanup)
    private lazy var launcher = LauncherPane()
    private lazy var launcherPage = ScrollingPage(launcher)
    private lazy var appSettings = GeneralPane(width: SettingsMetrics.width) {
        _ = restartRoost()
    }

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)

        contentViewController = NSHostingController(
            rootView: SettingsShellView(model: model))

        // Non-opaque, so the Liquid Glass behind the whole window can
        // composite -- see `Backdrop` in SettingsShell, which covers every
        // point of it. A titled window draws its own opaque background over
        // any material, and clearing the colour without clearing `isOpaque`
        // leaves it black.
        //
        // The glass once sat behind the content column only, and wherever
        // that column came out narrower than the pane, the window had
        // nothing in it at all and the desktop showed through. It is now
        // behind the split view itself, so no layout inside can uncover it.
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear

        isRestorable = true
        // The app holds the only reference and clears it in `onClose`, so the
        // window must survive its own close long enough to say so.
        isReleasedWhenClosed = false
        delegate = self

        // Shorter than the initial height by one header: the content can
        // scroll, and a window that cannot be made smaller than its first
        // size is a window that does not fit a laptop screen in a year's
        // time.
        minSize = NSSize(width: Self.initialSize.width,
                         height: Self.initialSize.height - SettingsMetrics.popupHeaderHeight)

        setFrameAutosaveName(Self.frameAutosaveKey)
        if !setFrameUsingName(Self.frameAutosaveKey) {
            positionForFirstRun()
        }
        setIsVisible(false)

        NotificationCenter.default.addObserver(
            self, selector: #selector(openRequested),
            name: .openModuleSettings, object: nil)

        show(.dashboard)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .openModuleSettings,
                                                  object: nil)
    }

    // MARK: - Opening

    /// Bring the window up, and optionally move it to a page.
    func open(module: String? = nil) {
        if !isVisible {
            setIsVisible(true)
            makeKeyAndOrderFront(nil)
        }
        if !isKeyWindow {
            orderFrontRegardless()
        }
        if let module {
            select(module)
        }
    }

    @objc private func openRequested(_ notification: Notification) {
        guard let name = notification.userInfo?["module"] as? String else { return }
        select(name)
    }

    /// Resolve a name and show it, or do nothing if it resolves to nothing.
    private func select(_ name: String) {
        guard let selection = SettingsSelection.resolve(
            name, moduleNames: ModuleRegistry.shared.all.map(\.moduleName))
        else { return }
        show(selection)
    }

    private func show(_ selection: SettingsSelection) {
        let view: NSView

        switch selection {
        case .module(let name):
            guard let module = ModuleRegistry.shared.named(name) else { return }
            // A module is allowed to have no settings page. An empty view is
            // the honest answer -- leaving the previous module's page up
            // would say this one's switches belong to it.
            view = ScrollingPage(module.makeSettingsPage() ?? NSView())
            model.moduleStates[name] = module.isEnabled

        case .dashboard:
            dashboard.viewWillAppear()
            view = dashboard

        case .appSettings:
            appSettings.viewWillAppear()
            view = appSettings

        case .cleanup:
            cleanup.viewWillAppear()
            view = cleanupPage

        case .launcher:
            launcher.viewWillAppear()
            view = launcherPage
        }

        NotificationCenter.default.post(
            name: .openWindow, object: nil,
            userInfo: selection.isModule
                ? ["module": selection.name, "state": true]
                : ["state": false])

        title = SettingsModel.title(for: selection.name)
        model.selection = selection.name
        model.detail = view
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        // Asynchronously, because the handler drops the app's reference to
        // this window and AppKit is still inside the close when it runs.
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        // Q as well as W, and that is deliberate. Roost is a menu bar app:
        // closing its one window is what somebody pressing ⌘Q in front of it
        // means, and quitting the whole monitor because they wanted the
        // settings window gone is not recoverable from the settings window.
        case 12, 13:
            close()
            return true
        case 46:
            miniaturize(event)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // The support window watches for this: a click anywhere in settings
        // is the signal that somebody is actually using the app.
        NotificationCenter.default.post(name: .clickInSettings, object: nil)
        super.mouseUp(with: event)
    }

    /// Where the window sits the very first time, before there is a saved
    /// frame.
    ///
    /// Horizontally centred, and above centre vertically -- `center()` puts a
    /// 480pt window low enough that the sidebar's last row is close to the
    /// Dock.
    private func positionForFirstRun() {
        guard let screen = NSScreen.main else {
            center()
            return
        }
        setFrameOrigin(NSPoint(
            x: (screen.frame.width - Self.initialSize.width) / 2,
            y: (screen.frame.height - Self.initialSize.height) / 1.75))
    }
}
