import AppKit
import SwiftUI

/// Clipboard history, as a Roost module.
///
/// A module rather than a window of its own, so it lives where the others
/// do: a switch in the sidebar, an item in the menu bar drawn by
/// `MonitorBar` -- individually or in the combined row, in the position the
/// user dragged it to -- a popup that is a `ReadingPopup` like every other,
/// and a settings page.
///
/// The module's switch is the menu bar item, and only that. Whether copies
/// are kept is `ClipboardSettings.monitoring`, a separate switch on the
/// settings page: history can run with no menu bar item, reached by its
/// shortcut, and the item can stay with capture off to reach old history.
final class ClipboardModule: PopupContent {

    static let shared = ClipboardModule()

    let title = "Clipboard"
    var menuBarLabel: String { "CLIP" }

    private let state = ClipboardPopupState()
    private var tile: NSView?
    private weak var popupView: NSView?

    // MARK: - Menu bar

    /// An icon, never a number: what is useful about the clipboard is one
    /// click away, not a figure to read at a glance. Faded while monitoring
    /// is off, so the item says whether it is recording without being
    /// opened.
    var defaultMenuBarStyles: [MenuBarStyle] { [.symbol] }
    var menuBarStyles: [MenuBarStyle] { [.symbol] }

    /// Reads one setting and nothing else. The clipboard is watched by
    /// `ClipboardService` on its own timer whether or not the item is in
    /// the menu bar, so drawing the item is not watching it.
    func menuBarContent() -> MenuBarReading? {
        MenuBarReading(label: menuBarLabel, symbol: "doc.on.clipboard",
                       dimmed: ClipboardService.shared.status != .on)
    }

    // MARK: - Popup

    func makeView() -> NSView {
        let host = NSHostingView(rootView: ClipboardPopupView(service: .shared, state: state))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        state.close = { [weak host] in (host?.window as? ReadingPopup)?.hide() }
        popupView = host
        return host
    }

    func willShow() {
        state.target = ClipboardActions.otherFrontmostApp
        state.opened += 1
        // Typing goes straight to the search. Done from here, by the window,
        // because SwiftUI's focus request did not take in a panel that is
        // key while its app is not active: the first renders showed the
        // header's gear holding focus and the field empty of a cursor.
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.popupView, let window = view.window,
                  let field = Self.firstTextField(in: view) else { return }
            window.makeFirstResponder(field)
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = firstTextField(in: child) { return found }
        }
        return nil
    }

    /// Nothing to sample: the view observes the service and redraws itself.
    func refresh() {}

    /// The combined popup's tile: three recent entries and the way to the rest.
    func makeTile() -> NSView {
        if let tile { return tile }
        let tileState = ClipboardPopupState()
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: localized("Clipboard"))
            ClipboardPopupView(service: .shared, state: tileState, tile: true)
        })
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        tileState.close = { [weak host] in (host?.window as? ReadingPopup)?.hide() }
        tile = host
        return host
    }

    /// The shortcut: the popup when the item is in the menu bar, the history
    /// window when it is not -- a history reachable only by a menu bar item
    /// somebody has hidden would be no history at all.
    func openFromShortcut() {
        if isEnabled, MonitorBar.shared.openPopup(for: title) { return }
        ClipboardHistoryWindow.present(over: ClipboardActions.otherFrontmostApp)
    }
}

extension ClipboardModule: RoostModule {

    var moduleName: String { "Clipboard" }
    var isAvailable: Bool { true }
    /// Off. A new menu bar item appearing after an update is an item nobody
    /// asked for, and history itself is off until it is turned on.
    var isOnByDefault: Bool { false }
    var hasPreview: Bool { false }

    var isEnabled: Bool {
        get { Preferences.shared.bool("Clipboard_state", default: false) }
        set {
            guard newValue != isEnabled else { return }
            Preferences.shared.set("Clipboard_state", newValue)
            newValue ? MonitorBar.shared.show(self) : MonitorBar.shared.hide(moduleName)
        }
    }

    /// The service starts here whatever the menu bar says: history is kept
    /// with the item hidden, and the item is only a way in.
    func start() {
        ClipboardService.shared.start()
        guard isEnabled else { return }
        MonitorBar.shared.show(self)
    }

    /// Called both when the item is switched off and at quit, so it takes
    /// the item away and nothing else. The service stops at quit, from the
    /// app delegate.
    func stop() {
        MonitorBar.shared.hide(moduleName)
    }

    var popupShortcut: [UInt16] { ClipboardSettings.shortcut }

    var menuBarWindow: NSWindow? { MonitorBar.shared.window(for: moduleName) }

    func makePortal() -> NSView? { makeTile() }

    func makeSettingsPage() -> NSView? { ClipboardSettingsPage() }
}
