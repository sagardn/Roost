//
//  SettingsShell.swift
//  Roost
//
//  The settings window's chrome, rebuilt in SwiftUI.
//
//  Why SwiftUI here: the old sidebar was a hand-rolled NSStackView of custom
//  MenuItem views, each tracking its own hover and selection state, inside a
//  scroll view sized by hand. Selection, keyboard navigation, search and the
//  sidebar material are all free in a List, and NavigationSplitView is what
//  macOS settings windows are made of now -- so this stops drifting further
//  from the platform with every release.
//
//  The module views themselves are untouched AppKit and are hosted as-is, so
//  each module can move to SwiftUI on its own schedule instead of in one
//  sweeping rewrite.
//

import SwiftUI

// MARK: - Model

/// What the shell draws, and the bridge to the notifications the rest of the
/// app already speaks.
final class SettingsModel: ObservableObject {

    struct Item: Identifiable, Hashable {
        let id: String          // the module name, or "Dashboard" / "Settings"
        let title: String
        let isModule: Bool
    }

    @Published var selection: String = "Dashboard"
    @Published var search: String = ""
    /// The AppKit view for the current selection. Resolved by SettingsWindow,
    /// which owns the module lookup.
    @Published var detail: NSView?
    @Published var moduleStates: [String: Bool] = [:]
    @Published var paused: Bool = Preferences.shared.bool("pause", default: false)

    let dashboard = Item(id: "Dashboard", title: SettingsModel.title(for: "Dashboard"), isModule: false)
    let appSettings = Item(id: "Settings", title: localized("Settings"), isModule: false)
    let cleanup = Item(id: "Free up space", title: localized("Free up space"), isModule: false)
    let launcher = Item(id: "Search & switcher", title: localized("Search & switcher"), isModule: false)
    private(set) var moduleItems: [Item] = []

    /// What a page is called on screen, which is not always its name.
    ///
    /// The Dashboard's name is what every notification and the menu bar's
    /// gear address it by, and it stays; what it is called is Overview,
    /// which is what it now is.
    static func title(for id: String) -> String {
        switch id {
        case "Dashboard": return localized("Overview")
        default:          return localized(id)
        }
    }

    init() {
        self.moduleItems = ModuleRegistry.shared.all
            .filter { $0.isAvailable }
            .map { Item(id: $0.moduleName,
                        title: localized($0.moduleName),
                        isModule: true) }
        self.moduleStates = Dictionary(uniqueKeysWithValues:
            ModuleRegistry.shared.all.map { ($0.moduleName, $0.isEnabled) })

        NotificationCenter.default.addObserver(
            self, selector: #selector(externalModuleToggle), name: .toggleModule, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(externalPause), name: .pause, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var filteredModules: [Item] { filtered(moduleItems) }

    /// The pages above and below the modules, filtered by the same search:
    /// typing "space" should find Free up space, not hide everything but
    /// the modules that do not match.
    var filteredPlaces: [Item] { filtered([dashboard, cleanup, launcher]) }
    var filteredSettings: [Item] { filtered([appSettings]) }

    private func filtered(_ items: [Item]) -> [Item] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Whether the current selection is a module, and whether it can preview.
    var selectedModule: (any RoostModule)? {
        ModuleRegistry.shared.named(selection)
    }

    // MARK: Intents

    /// Selection goes out as the same notification the old sidebar posted, so
    /// "open module X" from a menu bar click and a click in here take one path.
    func select(_ id: String) {
        NotificationCenter.default.post(name: .openModuleSettings, object: nil,
                                        userInfo: ["module": id])
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        moduleStates[name] = enabled

        // The switch used to do nothing but change its own appearance. It
        // set this dictionary, posted the notification below -- which only
        // this class observes, to set the same dictionary again -- and never
        // touched the module. So a module switched off kept its menu bar
        // item, kept sampling, and came back on as soon as the window was
        // reopened, because `moduleStates` is built from `isEnabled` at init
        // and `isEnabled` had never changed. Reproduced by switching Sensors
        // off and reading the defaults: `Sensors_state` was still 1.
        //
        // The machinery was already right: every module's `start()` returns
        // early unless it is enabled, and `stop()` takes its item out of the
        // bar. Nothing called either.
        if let module = ModuleRegistry.shared.named(name) {
            // Setting this persists the choice and adds or removes the menu
            // bar item on its own. Switching off also calls `stop()`, which
            // is the only thing that runs `willStop()` -- a module taken out
            // of the bar with a threshold alert still posted would keep
            // shouting about a reading nobody can see. Switching on needs
            // nothing further: every `start()` is a guard and a `show`, and
            // `show` is idempotent.
            module.isEnabled = enabled
            if !enabled { module.stop() }
        }

        NotificationCenter.default.post(name: .toggleModule, object: nil,
                                        userInfo: ["module": name, "state": enabled])
    }

    func togglePreview() {
        guard let module = selectedModule, module.hasPreview else { return }
        NotificationCenter.default.post(name: .togglePreview, object: nil,
                                        userInfo: ["module": module.moduleName])
    }

    func togglePause() {
        paused.toggle()
        Preferences.shared.set("pause", paused)
        NotificationCenter.default.post(name: .pause, object: nil, userInfo: ["state": paused])
    }

    @objc private func externalModuleToggle(_ notification: Notification) {
        guard let name = notification.userInfo?["module"] as? String,
              let state = notification.userInfo?["state"] as? Bool else { return }
        DispatchQueue.main.async { self.moduleStates[name] = state }
    }

    @objc private func externalPause() {
        let state = Preferences.shared.bool("pause", default: false)
        DispatchQueue.main.async { self.paused = state }
    }
}

// MARK: - Icons

/// One tinted tile per row, the way System Settings labels its own sidebar.
///
/// This replaces the modules' bundled bitmap icons: they were flat monochrome
/// PNGs of varying weight drawn at whatever size they happened to be, so the
/// column never lined up and nothing distinguished one row from the next but
/// the word beside it. SF Symbols are vector, come in matching weights, follow
/// the system font metrics, and pick up the colour per module -- which is what
/// makes a ten-row sidebar scannable.
struct Glyph {
    let symbol: String
    let color: Color

    /// The first symbol the running system actually has. SF Symbol names come
    /// and go between releases, so a missing one would otherwise render as a
    /// blank tile.
    private static func available(_ names: [String]) -> String {
        for name in names where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return "circle.grid.2x2"
    }

    static func named(_ id: String) -> Glyph {
        switch id {
        case "Dashboard":
            return Glyph(symbol: available(["square.grid.2x2.fill"]), color: .indigo)
        case "Settings":
            return Glyph(symbol: available(["gearshape.fill"]), color: .gray)
        case "Free up space":
            return Glyph(symbol: available(["sparkles"]), color: .pink)
        case "Search & switcher":
            return Glyph(symbol: available(["magnifyingglass"]), color: .purple)
        case "CPU":
            return Glyph(symbol: available(["cpu.fill", "cpu"]), color: .blue)
        case "GPU":
            return Glyph(symbol: available(["display", "tv"]), color: .purple)
        case "RAM":
            return Glyph(symbol: available(["memorychip.fill", "memorychip"]), color: .green)
        case "Disk":
            return Glyph(symbol: available(["internaldrive.fill", "internaldrive"]), color: .orange)
        case "Sensors":
            return Glyph(symbol: available(["thermometer.medium", "thermometer"]), color: .red)
        case "Network":
            return Glyph(symbol: available(["network"]), color: .teal)
        case "Battery":
            return Glyph(symbol: available(["battery.100percent", "battery.100"]), color: .green)
        case "Clipboard":
            return Glyph(symbol: available(["doc.on.clipboard.fill", "doc.on.clipboard"]), color: .cyan)
        default:
            return Glyph(symbol: available(["circle.grid.2x2.fill"]), color: .secondary)
        }
    }
}

// MARK: - Hosting an AppKit view

/// Puts a module's existing NSView in the detail pane. The view is swapped
/// rather than rebuilt, because modules keep their settings views alive and
/// expect to hand back the same instance.
private struct HostedView: NSViewRepresentable {
    let view: NSView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let current = container.subviews.first
        guard current !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

// MARK: - Glass

// MARK: - Glass

/// The window's ground: Liquid Glass where the system has it, vibrancy
/// before that, and the plain window colour under Reduce Transparency --
/// glass is exactly what that setting asks to see less of.
private struct Backdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            GlassBackdrop()
        }
    }
}

/// Regular glass, tinted a little with the window's own colour.
///
/// Untinted, regular glass is close to clear, and a page of small text read
/// against whatever window happened to be behind it. The tint is the
/// window background's own colour, so it follows the appearance: the glass
/// still shows what is behind it, softened enough that rows stay legible.
private struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.45)
            glass.contentView = NSView()
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Shell

struct SettingsShellView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 280)
        } detail: {
            HostedView(view: model.detail)
                // Take the whole pane, whatever the page inside wants to
                // be. SwiftUI sizes a hosted AppKit view to its fitting
                // size, so a page narrower than the window made this view
                // narrower too -- and the backdrop behind it shrank to
                // match, leaving the desktop showing between the sidebar
                // and the content.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 520, minHeight: 420)
                .toolbar { toolbarItems }
        }
        .navigationTitle(SettingsModel.title(for: model.selection))
        .modifier(PageTitledItself(active: model.selection == "Dashboard"))
        // Behind the split view, not behind one of its columns: one surface
        // for the whole window, which the columns' widths cannot uncover.
        .background(Backdrop().ignoresSafeArea())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Three groups, by what each is for: the pages about the Mac and
            // the launcher, the monitoring modules with their switches, and
            // Roost's own settings last -- where macOS puts them, and out of
            // the way of the pages reached for daily. Settings used to sit
            // between the Dashboard and Free up space, splitting the two
            // pages that are about the Mac.
            List(selection: selectionBinding) {
                if !model.filteredPlaces.isEmpty {
                    Section {
                        ForEach(model.filteredPlaces) { item in row(item) }
                    }
                }
                if !model.filteredModules.isEmpty {
                    Section(localized("Monitoring")) {
                        ForEach(model.filteredModules) { item in row(item) }
                    }
                }
                if !model.filteredSettings.isEmpty {
                    Section {
                        ForEach(model.filteredSettings) { item in row(item) }
                    }
                }
            }
            .listStyle(.sidebar)
            // Ten modules is enough that typing beats hunting.
            .searchable(text: $model.search,
                        placement: .sidebar,
                        prompt: localized("Search"))

            Divider()
            actionBar
        }
    }

    /// Selecting a row posts the notification; the window answers by setting
    /// `detail`, which is what actually moves the selection.
    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selection },
                set: { if let id = $0, id != model.selection { model.select(id) } })
    }

    private func row(_ item: SettingsModel.Item) -> some View {
        let on = !item.isModule || (model.moduleStates[item.id] ?? false)
        return HStack(spacing: 9) {
            GlyphTile(glyph: .named(item.id))
                // A module that is off reads as off before its switch is
                // found: the tile and the name fade, the switch says why.
                .opacity(on ? 1 : 0.45)
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(on ? .primary : .secondary)
            if item.isModule {
                Spacer(minLength: 4)
                // Enabling a module no longer means selecting it first.
                Toggle("", isOn: Binding(
                    get: { model.moduleStates[item.id] ?? false },
                    set: { model.setEnabled(item.id, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(localized("Toggle the module"))
                    // A switch with no label is "switch, on" to VoiceOver,
                    // in a column of six of them.
                    .accessibilityLabel(localized("%0 in the menu bar", item.title))
            }
        }
        .padding(.vertical, 3)
        .tag(item.id)
    }

    /// Five identical grey glyphs in a row told you nothing about which one
    /// quits the app and which one asks for money. Now the donation carries a
    /// word, the destructive action goes red under the pointer, pausing reads
    /// as a state rather than a button, and every one of them has a hit area
    /// you can see before you click it.
    private var actionBar: some View {
        HStack(spacing: 4) {
            if AppLinks.donationURL != nil {
                FooterButton(symbol: "heart.fill",
                             label: localized("Support"),
                             help: localized("Support the application"),
                             tint: .pink) {
                    if let url = AppLinks.donationURL { NSWorkspace.shared.open(url) }
                }
            }

            Spacer(minLength: 0)

            FooterButton(symbol: "ant.fill",
                         help: localized("Report a bug")) {
                // The report goes to the clipboard on the way to the issue
                // form, because the first reply to a bug report is always a
                // request for it. It was written and tested months before
                // this line, and reachable from nothing: `copyToPasteboard`
                // had no callers at all.
                Diagnostics.copyToPasteboard()
                Notify.show(localized("Diagnostics copied — paste them into the issue"),
                            symbol: "doc.on.doc")
                if let url = AppLinks.issuesURL { NSWorkspace.shared.open(url) }
            }
            FooterButton(symbol: model.paused ? "play.fill" : "pause.fill",
                         // Says what a click will do, which flips with the
                         // state: "Pause" on a paused app was an instruction
                         // that had already been followed.
                         help: model.paused ? localized("Resume the readings")
                                            : localized("Pause the readings"),
                         tint: model.paused ? .orange : nil,
                         isOn: model.paused) {
                model.togglePause()
            }
            FooterButton(symbol: "power",
                         help: localized("Quit Roost"),
                         hoverTint: .red) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let module = model.selectedModule, module.hasPreview {
                // An icon, not the word "Preview": it sits beside the enable
                // switch, and a toolbar full of prose reads as a form.
                Button {
                    model.togglePreview()
                } label: {
                    Image(systemName: "eye")
                }
                .help(localized("Preview"))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if let module = model.selectedModule {
                Toggle(localized("Toggle the module"), isOn: Binding(
                    get: { model.moduleStates[module.moduleName] ?? false },
                    set: { model.setEnabled(module.moduleName, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(localized("Toggle the module"))
            }
        }
    }
}

// MARK: - Footer button

/// A footer action with a visible hit area, hover feedback and an optional
/// label. The old row had none of the three: bare 33pt images with a tracking
/// area that set no state.
private struct FooterButton: View {
    let symbol: String
    var label: String?
    let help: String
    /// Resting colour, for an action worth spotting (the heart).
    var tint: Color?
    /// Colour under the pointer, for an action worth hesitating over (quit).
    var hoverTint: Color?
    /// Draws the button as engaged, for pause.
    var isOn: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var foreground: Color {
        if hovering, let hoverTint { return hoverTint }
        if let tint { return tint }
        return hovering ? .primary : .secondary
    }

    private var background: Color {
        if isOn { return (tint ?? .accentColor).opacity(0.18) }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        // Refuses to be compressed by its siblings. "Support"
                        // fits the sidebar; "Поддержать" does not, and without
                        // this it arrives as "Поддерж…" -- a truncation that
                        // only appears in a language nobody here reads.
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, label == nil ? 7 : 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        // `.help` is a tooltip, which VoiceOver does not read as the name:
        // without this the four icons were "button", four times.
        .accessibilityLabel(label ?? help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Takes the toolbar's title away on a page that draws its own.
///
/// The Overview opens with "Overview" in its header, beside the Mac it is
/// about, and the toolbar saying it again above that read as a stutter. The
/// window keeps its title -- the Window menu and Mission Control still say
/// Overview; only the toolbar's copy goes. `toolbar(removing: .title)` is
/// macOS 15; on 14 the title stays, which is a repeat and not a fault.
private struct PageTitledItself: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: active ? .title : nil)
        } else {
            content
        }
    }
}
