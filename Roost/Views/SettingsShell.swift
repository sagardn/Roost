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

    /// Modules that are utilities rather than readings. Clipboard has a
    /// menu bar item and an on/off state like the rest, but it measures
    /// nothing, and listed between Network and the next reading it was the
    /// one row in Monitoring that was not monitoring. It sits under Tools,
    /// and stays a module: its page and its menu bar switch are unchanged.
    static let utilityModules: Set<String> = ["Clipboard"]

    var filteredModules: [Item] {
        filtered(moduleItems.filter { !Self.utilityModules.contains($0.id) })
    }

    private static func item(_ tool: SettingsSelection.Tool) -> Item {
        Item(id: tool.rawValue, title: localized(tool.rawValue), isModule: false)
    }

    /// The top of the sidebar: how the Mac is, and the one scan that runs
    /// every tool below it.
    var filteredTop: [Item] { filtered([dashboard, Self.item(.checkUp)]) }

    /// The tools under their headings, filtered by the same search: typing
    /// "dup" should find Duplicates, not hide everything but the modules
    /// that match. A heading with nothing left under it is left out.
    var filteredGroups: [(title: String, items: [Item])] {
        SettingsSelection.Group.allCases.compactMap { group in
            var items = SettingsSelection.Tool.allCases
                .filter { $0.group == group }.map(Self.item)
            if group == .tools {
                items.append(launcher)
                items += moduleItems.filter { Self.utilityModules.contains($0.id) }
            }
            items = filtered(items)
            return items.isEmpty ? nil : (localized(group.rawValue), items)
        }
    }

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
        Self.setModule(name, enabled: enabled)
    }

    /// Turns a module on or off, from wherever the switch is: the module's
    /// own page, or the sidebar row's context menu. One path, so the two can
    /// never disagree about what switching does.
    static func setModule(_ name: String, enabled: Bool) {
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
                // Glass under the pages too, not only the sidebar: it is the
                // window's look, and it was asked for back the day it was
                // swapped for a solid ground. That swap fixed the Check-up's
                // start screen, one small block in an empty pane that read as
                // a page behind a broken overlay; the start screen now fills
                // its pane instead, which fixes it where the problem was.
                .toolbar { toolbarItems }
        }
        .navigationTitle(SettingsModel.title(for: model.selection))
        .modifier(PageTitledItself(active: Self.pagesTitledThemselves.contains(model.selection)))
        // Behind the split view, not behind one of its columns: one surface
        // for the whole window, which the columns' widths cannot uncover.
        .background(Backdrop().ignoresSafeArea())
    }

    /// Pages that open with their own heading, beside the action that
    /// belongs to it. Under the toolbar's copy of the same words, macOS
    /// protections and Background items each read their name twice, one
    /// line apart -- seen in a render of every page.
    static let pagesTitledThemselves: Set<String> = [
        "Dashboard",
        SettingsSelection.Tool.protection.rawValue,
        SettingsSelection.Tool.backgroundItems.rawValue
    ]

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Grouped by the job somebody came to do, the way Mac maintenance
            // apps lay themselves out: the Overview and the Check-up on top,
            // then each tool under Cleanup, Applications, Protection or
            // Tools, then the monitoring modules. The first group has
            // no heading, as System Settings' own first group has none: a
            // label over the two rows everything else hangs from says
            // nothing they do not. Roost's own settings are the gear in the bar at the bottom,
            // beside the app's other housekeeping. As a row of their own
            // under the modules they sat alone in the middle of the column,
            // read as one more page of equal weight, and were the first thing
            // a long module list pushed off the bottom.
            List(selection: selectionBinding) {
                if !model.filteredTop.isEmpty {
                    Section {
                        ForEach(model.filteredTop) { item in row(item) }
                    }
                }
                ForEach(model.filteredGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in row(item) }
                    }
                }
                if !model.filteredModules.isEmpty {
                    Section(localized("Monitoring")) {
                        ForEach(model.filteredModules) { item in row(item) }
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

    /// A row is a place to go and nothing else.
    ///
    /// The monitoring rows each carried an on/off switch, which made the
    /// bottom half of the column read as a settings form, put a control a
    /// click could land on inside a row whose click means "go there", and
    /// drew seven switches where a list should be. The switch is the first
    /// row of the module's page now. Here a module that is off says so --
    /// its tile goes grey and the row says Off -- and the context menu keeps
    /// the one-click way to change it without opening the page.
    private func row(_ item: SettingsModel.Item) -> some View {
        let on = !item.isModule || (model.moduleStates[item.id] ?? false)
        return HStack(spacing: RoostMetrics.sidebarRowSpacing) {
            GlyphTile(glyph: .named(item.id), size: RoostMetrics.sidebarGlyph, flat: true)
                .saturation(on ? 1 : 0)
                .opacity(on ? 1 : 0.5)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(on ? .primary : .secondary)
            if !on {
                Spacer(minLength: 4)
                Text(localized("Off"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, RoostMetrics.sidebarRowPadding)
        .contentShape(Rectangle())
        .tag(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "" : localized("Off"))
        .contextMenu {
            if item.isModule {
                Toggle(localized("Show in the menu bar"), isOn: Binding(
                    get: { model.moduleStates[item.id] ?? false },
                    set: { model.setEnabled(item.id, $0) }))
            }
        }
    }

    /// Five identical grey glyphs in a row told you nothing about which one
    /// quits the app and which one asks for money. Now the donation carries a
    /// word, the destructive action goes red under the pointer, pausing reads
    /// as a state rather than a button, and every one of them has a hit area
    /// you can see before you click it.
    ///
    /// Support on its own at the left, the app's housekeeping together at the
    /// right. The gear sat beside Support with the spacer after it, which
    /// split the four icons into one and three: measured in a render they
    /// stood 34, 30 and 30pt apart, and the gear read as part of the plea for
    /// money rather than as one of the app's own controls.
    private var actionBar: some View {
        HStack(spacing: RoostMetrics.sidebarFooterSpacing) {
            if AppLinks.donationURL != nil {
                FooterButton(symbol: "heart.fill",
                             label: localized("Support"),
                             help: localized("Support the application"),
                             tint: .pink) {
                    if let url = AppLinks.donationURL { NSWorkspace.shared.open(url) }
                }
            }

            Spacer(minLength: 0)

            FooterButton(symbol: "gearshape.fill",
                         help: localized("Settings"),
                         isOn: model.selection == model.appSettings.id) {
                model.select(model.appSettings.id)
            }
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
        .padding(.horizontal, RoostMetrics.sidebarFooterInset)
        .frame(height: RoostMetrics.sidebarFooterHeight)
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
        // No on/off switch here. It is the first row of the module's own page,
        // "Show in the menu bar", beside the rest of what the menu bar shows;
        // a second one in the window's corner read as a different setting.
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
                    .font(.system(size: RoostMetrics.sidebarFooterSymbol, weight: .medium))
                if let label {
                    Text(label)
                        .font(.system(size: RoostMetrics.sidebarFooterLabel, weight: .medium))
                        // Refuses to be compressed by its siblings. "Support"
                        // fits the sidebar; "Поддержать" does not, and without
                        // this it arrives as "Поддерж…" -- a truncation that
                        // only appears in a language nobody here reads.
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, label == nil ? 0 : RoostMetrics.sidebarFooterInset)
            // One square hit area for every icon, so the four utilities sit
            // on an even pitch rather than each as wide as its glyph.
            .frame(minWidth: RoostMetrics.sidebarFooterButton,
                   minHeight: RoostMetrics.sidebarFooterButton)
            .background(
                RoundedRectangle(cornerRadius: RoostMetrics.sidebarFooterRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: RoostMetrics.sidebarFooterRadius, style: .continuous))
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
