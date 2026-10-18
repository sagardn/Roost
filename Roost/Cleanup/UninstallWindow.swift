import AppKit
import SwiftUI

/// Remove an application or a command-line tool, and what it left behind.
///
/// Type a name, pick what you want gone, see every file that looks like its,
/// choose, and they go to the Bin. The matching and its confidence levels
/// are in `AppLeftovers` and `CommandLineTools`; this is the part somebody
/// looks at.
///
/// Two things it will not do. It does not delete -- everything Roost removes
/// itself goes to the Bin, so a wrong guess costs a trip to Finder rather
/// than somebody's data. And it never ticks a row it is not certain about: a
/// file matched only by a name is shown, labelled, and left for a person to
/// decide on.
///
/// The one exception is deliberate and is the reason the command is printed
/// in full before it runs. A tool Homebrew or npm installed is removed by
/// running *that manager's* uninstall command, because deleting
/// `Cellar/ripgrep` by hand leaves Homebrew's receipts claiming the formula
/// is still installed. Those files do not go to the Bin -- reinstalling is
/// how they come back -- so nothing runs without the exact command being
/// shown and agreed to.
///
/// Two panes rather than the stacked lists it replaces. Stacked, the lower
/// list had to share the window's height with the upper one, and capping it
/// at a third cut Safari's twenty leftovers down to five visible rows under
/// a header counting all twenty -- a missing row and an apparently wrong
/// total. Side by side, each list has the full height, and the selected row
/// on the left says which app the right is about, which nothing did before.
final class UninstallWindow: NSWindow, NSWindowDelegate, ClosableWindow {

    var onClose: (() -> Void)?

    private let model = UninstallModel()

    private static var open: UninstallWindow?

    static func present() {
        if let existing = open { existing.show(); return }
        let made = UninstallWindow()
        made.onClose = { UninstallWindow.open = nil }
        open = made
        made.show()
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                   styleMask: [.closable, .titled, .miniaturizable, .resizable,
                               .fullSizeContentView],
                   backing: .buffered, defer: true)

        title = localized("Remove an app or tool")
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self

        contentViewController = NSHostingController(rootView: UninstallView(model: model))
        setContentSize(NSSize(width: 780, height: 560))
        minSize = NSSize(width: 680, height: 460)
    }

    func windowWillClose(_ notification: Notification) {
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }

    func show() {
        setIsVisible(true)
        makeKeyAndOrderFront(nil)
        center()
        NSApp.activate(ignoringOtherApps: true)
        if model.apps.isEmpty { model.loadApps() }
    }

    /// Switches to the tools list from outside.
    ///
    /// Exists for `--render uninstall:tools`, which is the only way to look
    /// at a list that takes a few seconds to fill and find out that it looks
    /// wrong -- every layout bug in the window above was found that way and
    /// none of them were visible in the code.
    func selectTools(picking name: String? = nil) {
        model.pendingPick = name
        model.mode = .tools
    }
}

// MARK: - Model

final class UninstallModel: ObservableObject {

    enum Mode: Hashable { case apps, tools }

    struct App: Hashable {
        let name: String
        let bundleID: String
        let url: URL
    }

    @Published var mode: Mode = .apps {
        didSet {
            guard mode != oldValue else { return }
            query = ""
            clearChoice()
            if mode == .apps, apps.isEmpty { loadApps() }
            if mode == .tools, tools.isEmpty { loadTools() } else { applyPendingPick() }
        }
    }
    @Published var query = ""

    @Published private(set) var apps: [App] = []
    @Published private(set) var tools: [CommandLineTools.Tool] = []
    @Published private(set) var loadingList = false

    @Published private(set) var chosenApp: App?
    @Published private(set) var chosenTool: CommandLineTools.Tool?
    @Published private(set) var leftovers: [AppLeftovers.Item] = []
    @Published private(set) var lookingForLeftovers = false
    @Published private(set) var running = false
    @Published var selected: Set<URL> = []

    /// A tool to pick as soon as the list has finished filling.
    var pendingPick: String?

    var chosenName: String? { chosenApp?.name ?? chosenTool?.name }

    var shownApps: [App] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var shownTools: [CommandLineTools.Tool] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? tools : tools.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var chosen: [AppLeftovers.Item] { leftovers.filter { selected.contains($0.url) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }

    // MARK: Lists

    /// Everything in the Applications folders, by bundle.
    func loadApps() {
        loadingList = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var found: [App] = []
            for folder in ["/Applications", "/Applications/Utilities",
                           fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
                guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
                for name in names where name.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                    guard let bundle = Bundle(url: url),
                          let id = bundle.bundleIdentifier else { continue }
                    found.append(App(name: String(name.dropLast(4)), bundleID: id, url: url))
                }
            }
            let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = sorted
                self.loadingList = false
            }
        }
    }

    func loadTools() {
        loadingList = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = CommandLineTools.installed()
            DispatchQueue.main.async {
                self.tools = found
                self.loadingList = false
                self.applyPendingPick()
            }
        }
    }

    private func applyPendingPick() {
        guard let name = pendingPick, let tool = tools.first(where: { $0.name == name }) else { return }
        pendingPick = nil
        pick(tool)
    }

    // MARK: Picking

    private func clearChoice() {
        chosenApp = nil
        chosenTool = nil
        leftovers = []
        selected = []
        lookingForLeftovers = false
    }

    func pick(_ app: App) {
        guard chosenApp != app else { return }
        clearChoice()
        chosenApp = app
        lookingForLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppLeftovers.find(bundleID: app.bundleID, appName: app.name,
                                          includingBundle: app.url)
            DispatchQueue.main.async {
                guard self.chosenApp == app else { return }
                self.show(found)
            }
        }
    }

    func pick(_ tool: CommandLineTools.Tool) {
        guard chosenTool != tool else { return }
        clearChoice()
        chosenTool = tool
        lookingForLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = CommandLineTools.leftovers(for: tool)
            DispatchQueue.main.async {
                guard self.chosenTool?.location == tool.location else { return }
                self.show(found)
            }
        }
    }

    private func show(_ found: [AppLeftovers.Item]) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            lookingForLeftovers = false
            leftovers = found
            // Only what is certain. A file matched by name alone is shown,
            // labelled, and left for a person to decide on.
            selected = Set(found.filter(AppLeftovers.isTickedByDefault).map(\.url))
        }
    }

    func toggle(_ item: AppLeftovers.Item) {
        if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
    }

    /// What is on the list, in a line.
    ///
    /// One item is named rather than counted. Writing "1 items" is sloppy,
    /// and a singular form of the string would fix it only in the languages
    /// that have exactly two -- Russian and Polish need a third for 2-4.
    /// Naming the single item needs no plural anywhere.
    var summary: String {
        guard let name = chosenName else { return "" }
        guard !leftovers.isEmpty else {
            // A managed tool with no stray files is the normal case, not a
            // dead end: its own command is still sitting above.
            return chosenTool?.isManaged == true
                ? localized("%0 is removed by the command below", name)
                : localized("%0 left nothing behind that Roost can see", name)
        }
        let total = Readings.bytes(UInt64(totalBytes))
        if let only = leftovers.first, leftovers.count == 1 {
            return localized("%0 — %1, %2", name, only.name, total)
        }
        return localized("%0 — %1 items, %2 in total", name, String(leftovers.count), total)
    }

    // MARK: Removing

    func moveChosenToBin() {
        let items = chosen
        guard !items.isEmpty, let name = chosenName else { return }

        let bytes = UInt64(items.reduce(Int64(0)) { $0 + $1.bytes })
        // The count and the size, because the decision is "is this the right
        // thing" and the size is the only hint that it might not be.
        let detail: String
        if let only = items.first, items.count == 1 {
            detail = localized("%0, %1, goes to the Bin. Nothing is erased — it can be put back from Finder.",
                               only.name, Readings.bytes(bytes))
        } else {
            detail = localized("%0 items, %1, go to the Bin. Nothing is erased — everything can be put back from Finder.",
                               String(items.count), Readings.bytes(bytes))
        }
        Alert.show(localized("Remove %0?", name), detail,
                   style: .warning,
                   actionTitle: localized("Move to Bin")) { [weak self] in
            let removal = AppLeftovers.moveToBin(items)
            Notify.show(LargeFiles.message(for: removal), symbol: "trash")
            guard let self else { return }
            let moved = Set(removal.moved)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                self.leftovers.removeAll { moved.contains($0.url) }
                self.selected.subtract(moved)
            }
        }
    }

    /// Hands the removal to the manager that did the installing.
    func runCommand() {
        guard let tool = chosenTool, let command = tool.command else { return }

        Alert.show(localized("Run %0?", command.text),
                   localized("Roost runs %0's own uninstaller. What that removes does not go to the Bin — installing it again is how it comes back.",
                             tool.kind.label),
                   style: .warning,
                   actionTitle: localized("Run")) { [weak self] in
            guard let self else { return }
            self.running = true

            CommandLineTools.run(command) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running = false
                    if result.succeeded {
                        Notify.show(localized("%0 removed", tool.name), symbol: "checkmark.circle")
                        // The manager has gone; the dotfiles it never knew
                        // about have not, so the leftovers stay on screen
                        // under the tool's name rather than being cleared.
                        self.tools.removeAll { $0 == tool }
                        self.chosenTool = CommandLineTools.Tool.removed(tool)
                    } else {
                        // Its own words. "Cannot uninstall, it is required by
                        // ..." is the useful part and no summary of ours beats it.
                        Alert.show(localized("%0 could not be removed", tool.name),
                                   Self.tail(of: result.output), style: .warning)
                    }
                }
            }
        }
    }

    /// The end of the output, which is where a package manager puts the
    /// reason it refused.
    private static func tail(of output: String, limit: Int = 1200) -> String {
        guard !output.isEmpty else { return localized("It said nothing about why.") }
        guard output.count > limit else { return output }
        return "…" + String(output.suffix(limit))
    }
}

private extension CommandLineTools.Tool {
    /// The same tool with its command gone, once the manager has removed it,
    /// so the right pane keeps its name over the dotfiles that remain but no
    /// longer offers to run an uninstall that already ran.
    static func removed(_ tool: CommandLineTools.Tool) -> CommandLineTools.Tool {
        CommandLineTools.Tool(name: tool.name, kind: tool.kind, location: tool.location,
                              bytes: tool.bytes, detail: tool.detail, command: nil)
    }
}

// MARK: - Views

private struct UninstallView: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        HStack(spacing: 0) {
            ChooserPane(model: model)
                .frame(width: 260)
            Divider().opacity(0.6)
            DetailPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 28)
        .frame(minWidth: 680, minHeight: 460)
        .background(CleanerBackdrop().ignoresSafeArea())
    }
}

/// The left: Apps or Command-line tools, a search, and the list.
private struct ChooserPane: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 10) {
            Picker(selection: $model.mode) {
                Text(localized("Apps")).tag(UninstallModel.Mode.apps)
                Text(localized("Command-line tools")).tag(UninstallModel.Mode.tools)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SearchBox(text: $model.query,
                      prompt: model.mode == .apps ? localized("Search installed apps…")
                                                  : localized("Search command-line tools…"))

            if model.loadingList {
                Spacer()
                ProgressView().controlSize(.small)
                Text(localized("Looking…")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else if model.mode == .tools && model.tools.isEmpty {
                Spacer()
                Text(localized("No command-line tools found"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                list
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollViewReader { reader in
        ScrollView {
            // Not lazy: a lazy row that has never been on screen cannot be
            // scrolled to, which left a picked tool selected out of sight.
            // A hundred apps is nothing to lay out eagerly.
            VStack(spacing: 1) {
                switch model.mode {
                case .apps:
                    ForEach(model.shownApps, id: \.self) { app in
                        ChooserRow(title: app.name, subtitle: nil,
                                   icon: .file(app.url),
                                   isOn: model.chosenApp == app) { model.pick(app) }
                    }
                case .tools:
                    ForEach(model.shownTools, id: \.location) { tool in
                        ChooserRow(title: tool.name, subtitle: Self.note(for: tool),
                                   icon: .symbol("terminal"),
                                   isOn: model.chosenTool?.location == tool.location) {
                            model.pick(tool)
                        }
                        .id(tool.location)
                    }
                }
            }
        }
        // A pick that did not come from a click -- `selectTools(picking:)` --
        // lands on a row that may be far down the list, and a selection
        // nobody can see is the bug this layout exists to fix.
        //
        // On appear as well as on change, because that pick arrives in the
        // same turn as the list itself and so is never a change to it; and a
        // turn later in both, so the rows have been laid out.
        .onChange(of: model.chosenTool?.location) { _, location in
            scroll(reader, to: location)
        }
        .onAppear { scroll(reader, to: model.chosenTool?.location) }
        }
    }

    private func scroll(_ reader: ScrollViewProxy, to location: URL?) {
        guard let location else { return }
        DispatchQueue.main.async {
            withAnimation { reader.scrollTo(location, anchor: .center) }
        }
    }

    /// Where it came from and how big it is. Two tools can share a name
    /// across the two Homebrew prefixes, so the row has to say more than the
    /// name for the right one to be picked.
    private static func note(for tool: CommandLineTools.Tool) -> String {
        var note = tool.kind.label
        if let detail = tool.detail, tool.isManaged { note += " \(detail)" }
        if tool.bytes > 0 { note += " · \(Readings.bytes(UInt64(tool.bytes)))" }
        return note
    }
}

private struct SearchBox: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(localized("Clear the search"))
                .accessibilityLabel(localized("Clear the search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }
}

private enum RowIcon {
    case file(URL)
    case symbol(String)
}

private struct ChooserRow: View {
    let title: String
    let subtitle: String?
    let icon: RowIcon
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                iconView.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.8))
                                                  : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Color.accentColor.gradient)
                               : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().interpolation(.high)
        case .symbol(let name):
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOn ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
                .overlay(Image(systemName: name).font(.system(size: 11, weight: .semibold)))
        }
    }
}

/// The right: what the chosen app or tool left behind.
private struct DetailPane: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        if model.chosenName == nil {
            EmptyChoice(mode: model.mode)
        } else {
            VStack(spacing: 0) {
                DetailHeader(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                if let command = model.chosenTool?.command {
                    CommandCard(command: command, running: model.running) { model.runCommand() }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                Divider().opacity(0.6)
                if model.lookingForLeftovers {
                    Spacer()
                    ScanRing(progress: 0, tint: CleanerTint.calm, lineWidth: 5, scanning: true)
                        .frame(width: 90, height: 90)
                    Text(localized("Looking…"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                    Spacer()
                } else if model.leftovers.isEmpty {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(CleanerTint.calm)
                    Spacer()
                } else {
                    leftoverList
                    Divider().opacity(0.6)
                    footer
                }
            }
        }
    }

    private var leftoverList: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let largest = Double(max(1, model.leftovers.map(\.bytes).max() ?? 1))
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.leftovers, id: \.url) { item in
                    LeftoverRow(item: item, home: home,
                                share: Double(item.bytes) / largest,
                                isOn: model.selected.contains(item.url)) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { model.toggle(item) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !model.chosen.isEmpty {
                Text(localized("%0 selected · %1",
                               String(model.chosen.count), Readings.bytes(UInt64(model.chosenBytes))))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            GlowButton(title: model.chosen.count > 1 ? localized("Move %0 to Bin", String(model.chosen.count))
                                                     : localized("Move to Bin"),
                       symbol: "trash", tint: CleanerTint.critical, compact: true,
                       enabled: !model.chosen.isEmpty) {
                model.moveChosenToBin()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.chosen.count)
    }
}

private struct EmptyChoice: View {
    let mode: UninstallModel.Mode

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(CleanerTint.critical.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: mode == .apps ? "xmark.bin.fill" : "terminal.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(CleanerTint.critical.gradient)
            }
            Text(mode == .apps ? localized("Pick an app to see what it left behind")
                               : localized("Pick a tool to see what it left behind"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct DetailHeader: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let app = model.chosenApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay(Image(systemName: "terminal")
                            .font(.system(size: 22, weight: .semibold)))
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.chosenName ?? "")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(model.lookingForLeftovers ? localized("Looking…")
                     : model.running ? localized("Running %0…", model.chosenTool?.command?.text ?? "")
                     : model.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The package manager's own command, in full, before anything runs.
private struct CommandCard: View {
    let command: CommandLineTools.Command
    let running: Bool
    let run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CleanerTint.calm)
            // Selectable: somebody who would rather run it in their own
            // shell should be able to take it out of here.
            Text(command.text)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(localized("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command.text, forType: .string)
                Notify.show(localized("Command copied"), symbol: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if running {
                ProgressView().controlSize(.small)
            } else {
                Button(localized("Run"), action: run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// One leftover: what it is, where, how big, and how sure we are.
private struct LeftoverRow: View {
    let item: AppLeftovers.Item
    let home: URL
    let share: Double
    let isOn: Bool
    let toggle: () -> Void

    @State private var hovering = false

    /// Where it is, and -- for anything less than certain -- why it is here
    /// at all. A row somebody is asked to judge has to say what the
    /// judgement is about.
    private var note: Text {
        let place = Text(Self.folder(item.url, home: home))
        switch item.confidence {
        case .certain:
            return place
        case .likely:
            return place + Text(" · ") + Text(localized("probably this app"))
        case .possible:
            return place + Text(" · ")
                + Text(localized("matched by name only")).foregroundColor(CleanerTint.warning)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(tick: isOn ? .all : .none, tint: CleanerTint.critical)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                note
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(item.url.path)
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(CleanerTint.critical.opacity(0.8).gradient)
                    .frame(width: 56 * CGFloat(max(0.04, min(1, share))))
            }
            .frame(width: 56, height: 5)
            // Hidden rather than empty, so an unmeasured row does not read as
            // the smallest thing on the list.
            .opacity(item.isMeasured ? 1 : 0)
            SizeText(bytes: item.bytes, isMeasured: item.isMeasured)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .tertiary)
            .help(localized("Reveal"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? CleanerTint.critical.opacity(0.10)
                       : Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu { Button(localized("Reveal")) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private static func folder(_ url: URL, home: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        guard parent.hasPrefix(home.path) else { return parent }
        let trimmed = String(parent.dropFirst(home.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "~" : trimmed
    }
}

/// A size, or a dash for one that could not be read.
///
/// The dash, not "0 B": `AppLeftovers.measure` returns nil for a folder that
/// would not open, and zero is the one thing that is certainly wrong about
/// it -- an unreadable folder is unreadable because of what guards it, not
/// because it is small. The reason is on hover, where there is room for it.
struct SizeText: View {
    let bytes: Int64
    let isMeasured: Bool

    var body: some View {
        Text(isMeasured ? Readings.bytes(UInt64(max(0, bytes))) : "—")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isMeasured ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 64, alignment: .trailing)
            .help(isMeasured ? "" : localized("Size unknown: macOS would not let Roost look inside"))
    }
}
