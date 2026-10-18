import AppKit
import SwiftUI

/// What the AI assistants are holding, and what can go.
///
/// The tools stay installed and stay signed in; this is about what they have
/// accumulated behind them. Caches, logs and downloaded updates arrive
/// ticked because the tool rebuilds them without noticing. Conversations and
/// memory arrive unticked, however large they are: somebody who resumes old
/// sessions loses them, and that is their call rather than a default.
///
/// Everything goes to the Bin. `AIAssistants` decides what is offered at
/// all, by an allowlist of names, so nothing here can reach a credential;
/// this view only draws what it was handed and never widens it.
///
/// There is deliberately no box that ticks a whole assistant. It would be
/// the quickest click on the page, and it would tick that assistant's
/// conversations along with its caches -- 462 MB of `~/.claude/projects`
/// measured here, the one row in this area that costs somebody real work.
/// Each conversation row has to be ticked on its own.
final class AICleanupWindow: NSWindow, NSWindowDelegate, ClosableWindow {

    var onClose: (() -> Void)?

    private let model = AICleanupModel()

    private static var open: AICleanupWindow?

    static func present() {
        if let existing = open { existing.show(); return }
        let made = AICleanupWindow()
        made.onClose = { AICleanupWindow.open = nil }
        open = made
        made.show()
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                   styleMask: [.closable, .titled, .miniaturizable, .resizable,
                               .fullSizeContentView],
                   backing: .buffered, defer: true)

        title = localized("Clean up AI assistants")
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self

        contentViewController = NSHostingController(rootView: AICleanupView(model: model))
        setContentSize(NSSize(width: 640, height: 600))
        minSize = NSSize(width: 540, height: 460)
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
        if !model.loaded && !model.loading { model.load() }
    }
}

// MARK: - Model

final class AICleanupModel: ObservableObject {

    /// Everything the one scan found, before the age rule.
    @Published private(set) var found: [AIAssistants.Tool] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var selected: Set<URL> = []

    /// The age rule: only what has gone unused this many days, nil for any
    /// age. Applied to the one scan rather than rescanning, so moving the
    /// picker is instant.
    @Published var days: Int? = AICleanupModel.storedDays {
        didSet { Preferences.shared.set("AICleaner_days", days ?? -1) }
    }

    static let dayChoices: [Int?] = [nil, 30, 90, 180]

    /// 0 or absent is the default of 90; -1 is "any age".
    private static var storedDays: Int? {
        let stored = Preferences.shared.int("AICleaner_days", default: 0)
        if stored < 0 { return nil }
        return stored == 0 ? 90 : stored
    }

    /// What the age rule leaves on offer. A tick on something the rule hides
    /// stays in `selected` but is never acted on: `chosen` only reads what is
    /// on screen, so a filter can never hide something about to be moved.
    var tools: [AIAssistants.Tool] { AIAssistants.offered(found, olderThan: days) }

    var allItems: [AIAssistants.Item] { tools.flatMap(\.items) }
    var chosen: [AIAssistants.Item] { allItems.filter { selected.contains($0.url) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { tools.reduce(0) { $0 + $1.bytes } }
    var choosesConversations: Bool { chosen.contains { $0.kind == .conversations } }

    /// Scans off the main thread: it stats every file under half a dozen
    /// directories, and ~/.codex alone held 2.4 GB of them.
    func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AIAssistants.find()
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                    self.found = found
                    self.selected = Set(found.flatMap(\.items)
                        .filter { $0.kind.isTickedByDefault }
                        .map(\.url))
                    self.loading = false
                    self.loaded = true
                }
            }
        }
    }

    /// One line of an assistant's card: a store on its own, or the
    /// conversations that share a context -- a project, a day.
    ///
    /// Grouped because a conversation store now arrives one conversation at
    /// a time, 164 rows on this Mac, and a card of a hundred "Roost · 2664aea4"
    /// lines buries the cache rows that are the reason somebody opened it.
    enum Entry {
        case item(AIAssistants.Item)
        case group(context: String, items: [AIAssistants.Item])

        var id: String {
            switch self {
            case .item(let item):           return item.url.path
            case .group(let context, _):    return "group:" + context
            }
        }
    }

    /// Biggest first by what each line holds -- a section by its total, not
    /// by its largest conversation, or a project of thirty small sessions
    /// sorts below one with a single big one. Ties keep arrival order. A
    /// context with only one conversation stays a row: a section that opens
    /// onto one line is a click for nothing.
    static func entries(of tool: AIAssistants.Tool) -> [Entry] {
        var byContext: [String: [AIAssistants.Item]] = [:]
        for item in tool.items {
            if let context = item.context { byContext[context, default: []].append(item) }
        }
        var entries: [Entry] = []
        var placed: Set<String> = []
        for item in tool.items {
            guard let context = item.context, let group = byContext[context], group.count > 1 else {
                entries.append(.item(item))
                continue
            }
            guard placed.insert(context).inserted else { continue }
            entries.append(.group(context: context, items: group))
        }
        let sized: [(offset: Int, bytes: Int64, entry: Entry)] = entries.enumerated().map {
            switch $0.element {
            case .item(let item):          return ($0.offset, item.bytes, $0.element)
            case .group(_, let items):     return ($0.offset, items.reduce(0) { $0 + $1.bytes }, $0.element)
            }
        }
        return sized.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.offset < $1.offset }
            .map(\.entry)
    }

    /// Closed by default, and remembered only while the window is open.
    @Published var open: Set<String> = []

    static func groupKey(_ tool: AIAssistants.Tool, _ context: String) -> String {
        tool.name + "\u{1}" + context
    }

    func toggleOpen(_ key: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }

    func tick(_ items: [AIAssistants.Item]) -> CleanerModel.Tick {
        let ticked = items.filter { selected.contains($0.url) }.count
        if ticked == 0 { return .none }
        return ticked == items.count ? .all : .some
    }

    /// A whole project's conversations at once. Allowed here, unlike a whole
    /// assistant, because the box sits on a row that says "conversations"
    /// in amber and holds nothing else -- the choice is about exactly one
    /// kind of thing, and it is never made by default.
    func toggle(_ items: [AIAssistants.Item]) {
        let urls = Set(items.map(\.url))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            if tick(items) == .all { selected.subtract(urls) } else { selected.formUnion(urls) }
        }
    }

    func toggle(_ item: AIAssistants.Item) {
        if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
    }

    func moveChosenToBin() {
        let items = chosen
        guard !items.isEmpty else { return }

        let bytes = UInt64(items.reduce(Int64(0)) { $0 + $1.bytes })
        // Said plainly, because it is the one thing here that does not come
        // back on its own. Caches and logs are rebuilt; a conversation is
        // not.
        let detail = choosesConversations
            ? localized("%0 goes to the Bin, including conversation history. The assistants stay installed and signed in, but old sessions will not be there to resume.",
                        Readings.bytes(bytes))
            : localized("%0 goes to the Bin. The assistants stay installed and signed in, and rebuild what they need.",
                        Readings.bytes(bytes))

        Alert.show(localized("Clean up %0?", Readings.bytes(bytes)), detail,
                   style: .warning,
                   actionTitle: localized("Move to Bin")) { [weak self] in
            // With the age, so it is checked again against the disk: the list
            // can be minutes old, and something used since is refused.
            let removal = AIAssistants.moveToBin(items, olderThan: self?.days)
            Notify.show(LargeFiles.message(for: removal), symbol: "trash")
            guard let self else { return }
            let moved = Set(removal.moved)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                self.found = self.found.compactMap { tool in
                    let kept = tool.items.filter { !moved.contains($0.url) }
                    return kept.isEmpty ? nil : AIAssistants.Tool(name: tool.name, items: kept)
                }
                self.selected.subtract(moved)
            }
        }
    }
}

// MARK: - Views

private struct AICleanupView: View {
    @ObservedObject var model: AICleanupModel

    var body: some View {
        ZStack {
            if model.loading || !model.loaded {
                VStack(spacing: 14) {
                    ScanRing(progress: 0, tint: CleanerTint.calm, lineWidth: 8, scanning: true)
                        .frame(width: 150, height: 150)
                    Text(localized("Looking…"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if model.tools.isEmpty && !model.found.isEmpty {
                VStack(spacing: 14) {
                    AgePicker(days: $model.days)
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(CleanerTint.calm)
                        .padding(.top, 10)
                    // The amount, not only the fact: "2.7 GB hidden" reads as a
                    // setting doing its job, where an empty list reads as a
                    // scan that broke.
                    Text(localized("%0 hidden by the %1-day rule",
                                   Readings.bytes(UInt64(AIAssistants.hidden(model.found,
                                                                             olderThan: model.days))),
                                   String(model.days ?? 0)))
                        .font(.system(size: 14, weight: .semibold))
                    Text(localized("Everything the assistants hold has been used more recently than that."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    CleanerLink(title: localized("Show everything"), symbol: "eye") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.days = nil }
                    }
                }
                .padding(.horizontal, 30)
                .transition(.opacity)
            } else if model.tools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text(localized("No AI assistants found on this Mac"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                results.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 540, minHeight: 460)
        .background(CleanerBackdrop().ignoresSafeArea())
    }

    private var results: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 14)
            Divider().opacity(0.6)
            list
            Divider().opacity(0.6)
            footer
        }
    }

    private var header: some View {
        let share = Double(model.chosenBytes) / Double(max(1, model.totalBytes))
        return HStack(spacing: 14) {
            ZStack {
                ScanRing(progress: share, tint: CleanerTint.calm, lineWidth: 6, scanning: false)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CleanerTint.calm.gradient)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(localized("%0 across %1 assistants",
                               Readings.bytes(UInt64(model.totalBytes)), String(model.tools.count)))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(localized("Conversation history, caches, logs and downloaded updates. The tools stay installed and signed in."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AgePicker(days: $model.days)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        let largest = Double(max(1, model.allItems.map(\.bytes).max() ?? 1))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.tools, id: \.name) { tool in
                    VStack(spacing: 2) {
                        AssistantHeader(tool: tool)
                        ForEach(AICleanupModel.entries(of: tool), id: \.id) { entry in
                            switch entry {
                            case .item(let item):
                                row(item, largest: largest, inGroup: false)
                            case .group(let context, let items):
                                let key = AICleanupModel.groupKey(tool, context)
                                ConversationGroup(context: context, items: items,
                                                  share: Double(items.reduce(0) { $0 + $1.bytes }) / largest,
                                                  tick: model.tick(items),
                                                  isOpen: model.open.contains(key),
                                                  open: { model.toggleOpen(key) },
                                                  toggle: { model.toggle(items) })
                                if model.open.contains(key) {
                                    ForEach(items, id: \.url) { item in
                                        row(item, largest: largest, inGroup: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035)))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func row(_ item: AIAssistants.Item, largest: Double, inGroup: Bool) -> some View {
        AIItemRow(item: item,
                  share: Double(item.bytes) / largest,
                  isOn: model.selected.contains(item.url),
                  inGroup: inGroup) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                model.toggle(item)
            }
        }
    }

    /// What the button is about to act on, in words.
    ///
    /// The header's "2.9 GB across 7 assistants" is everything the scan
    /// offered; the button's figure is only what is ticked. With nothing
    /// saying so the two read as a contradiction -- the ring at the top
    /// already encodes exactly this ratio and nothing labels it either.
    ///
    /// Both lines come from `chosen`, the same array `moveChosenToBin` acts
    /// on, so the words and the button cannot drift apart. In particular the
    /// count is of what is ticked *and still offered*: a tick hidden by the
    /// age rule is not counted here, because it is not going to be moved.
    ///
    /// "shown", not "found": `totalBytes` is the total of what the age rule
    /// lets through, which is also the figure in the header, and with a rule
    /// in force the scan found more than that. `AIAssistants.hidden` is what
    /// the difference is, and the empty state is where it is reported.
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.chosen.isEmpty {
                // The same line, the same font and the same key as the other
                // two cleanup windows' footers. It takes a count and a size
                // and names no noun, which is why "1 selected" needs no
                // singular form in any language.
                Text(localized("%0 selected · %1", String(model.chosen.count),
                               Readings.bytes(UInt64(model.chosenBytes))))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Text(localized("of %0 shown", Readings.bytes(UInt64(model.totalBytes))))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            selectionSummary
            if model.choosesConversations {
                // In the footer as well as in the alert: the alert is read
                // after the decision, this is read while it is being made.
                Label(localized("conversations and memory"), systemImage: "exclamationmark.bubble.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CleanerTint.warning)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(CleanerTint.warning.opacity(0.14)))
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 8)
            // The size, not the count: freeing 1.2 GB is the decision, and
            // "Move 9 to Bin" says nothing about whether it is worth it.
            GlowButton(title: model.chosen.isEmpty
                       ? localized("Move to Bin")
                       : localized("Move %0 to Bin", Readings.bytes(UInt64(model.chosenBytes))),
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

/// One assistant's name, with what it is holding in total.
private struct AssistantHeader: View {
    let tool: AIAssistants.Tool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.pink.gradient)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white))
            Text(Self.displayName(tool.name))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(Readings.bytes(UInt64(tool.bytes)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.trailing, 34)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The product's own name for what `AIAssistants` reports by folder.
    /// Brand names, so not localised; anything unknown is capitalised rather
    /// than shown as a lowercase directory name.
    static func displayName(_ name: String) -> String {
        let known: [String: String] = [
            "claude": "Claude Code", "codex": "Codex", "grok": "Grok", "gemini": "Gemini",
            "copilot": "GitHub Copilot", "opencode": "OpenCode", "cursor": "Cursor",
            "windsurf": "Windsurf", "aider": "Aider", "continue": "Continue", "amp": "Amp",
            "qwen": "Qwen Code", "goose": "Goose", "crush": "Crush",
            "antigravity": "Antigravity", "chatgpt": "ChatGPT",
            "huggingface": "Hugging Face", "ollama": "Ollama", "lm studio": "LM Studio"
        ]
        return known[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// "Unused for: Any time · 30+ · 90+ · 180+ days".
///
/// The options read "30+ days" rather than "30 days" because the rule is
/// `lastUsed < now - days` -- not used in *at least* that long. "30 days"
/// invited reading it as the opposite, as everything touched within the
/// month. The no-filter option was "Any age", which named the wrong quantity:
/// nothing here is measured by how old a file is, only by how long it has
/// gone unused.
private struct AgePicker: View {
    @Binding var days: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(localized("Unused for"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Picker(selection: $days) {
                ForEach(AICleanupModel.dayChoices, id: \.self) { choice in
                    Text(choice.map { localized("%0+ days", String($0)) } ?? localized("Any time"))
                        .tag(choice)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// One store: what it is, what kind, how big.
private struct AIItemRow: View {
    let item: AIAssistants.Item
    let share: Double
    let isOn: Bool
    /// Inside a context's section, which already names the context.
    var inGroup = false
    let toggle: () -> Void

    @State private var hovering = false

    private var isConversation: Bool { item.kind == .conversations }

    /// `displayName` -- "Roost · 2664aea4" rather than a UUID -- without the
    /// context when the section header above already says it.
    private var title: String {
        let full = item.displayName
        guard inGroup, let context = item.context, full.hasPrefix(context + " · ") else { return full }
        return String(full.dropFirst(context.count + 3))
    }

    private var symbol: String {
        switch item.kind {
        case .conversations: return "bubble.left.and.bubble.right.fill"
        case .caches:        return "archivebox.fill"
        case .logs:          return "doc.text.fill"
        case .downloads:     return "arrow.down.circle.fill"
        case .models:        return "cube.box.fill"
        }
    }

    /// When it was last touched, in the system's own words and language --
    /// "3 months ago" -- which is what the age rule above is measured on.
    private var lastUsed: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: item.lastUsed, relativeTo: Date())
    }

    /// Conversations are the row somebody has to think about, so they are
    /// the row that is coloured; everything else is the calm teal of
    /// "rebuilt without noticing".
    private var tint: Color {
        switch item.kind {
        case .conversations: return CleanerTint.warning
        // Never ticked, like conversations, but for a different reason --
        // they cost a download, not somebody's work -- so not the same amber.
        case .models:        return Color(nsColor: .roostBlue)
        default:             return CleanerTint.calm
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(tick: isOn ? .all : .none,
                        tint: isConversation ? CleanerTint.warning : CleanerTint.critical)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 0) {
                    // A directory called `cache` under a line reading "cache"
                    // says nothing twice.
                    if item.kind.label.caseInsensitiveCompare(item.name) != .orderedSame {
                        Text(item.kind.label)
                            .font(.system(size: 10.5, weight: isConversation ? .semibold : .regular))
                            .foregroundStyle(isConversation ? AnyShapeStyle(CleanerTint.warning)
                                                            : AnyShapeStyle(.secondary))
                        Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Text(lastUsed)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            .help(item.url.path)
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.gradient)
                    .frame(width: 56 * CGFloat(max(0.04, min(1, share))))
            }
            .frame(width: 56, height: 5)
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
        .padding(.leading, inGroup ? 34 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, inGroup ? 5 : 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? (isConversation ? CleanerTint.warning : CleanerTint.critical).opacity(0.10)
                       : Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The conversations that share a project or a day, as one line that opens.
private struct ConversationGroup: View {
    let context: String
    let items: [AIAssistants.Item]
    let share: Double
    let tick: CleanerModel.Tick
    let isOpen: Bool
    let open: () -> Void
    let toggle: () -> Void

    @State private var hovering = false

    private var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var newest: Date { items.map(\.lastUsed).max() ?? Date() }

    var body: some View {
        HStack(spacing: 10) {
            // Its own button: the row's click opens the section, and a box
            // that also opened it would turn every choice into a scroll.
            Button(action: toggle) {
                CheckCircle(tick: tick, tint: CleanerTint.warning)
            }
            .buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(context)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 0) {
                    Text(localized("%0 conversations", String(items.count)))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CleanerTint.warning)
                    Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Text(Self.relative(newest))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(CleanerTint.warning.gradient)
                    .frame(width: 56 * CGFloat(max(0.04, min(1, share))))
            }
            .frame(width: 56, height: 5)
            SizeText(bytes: bytes, isMeasured: items.allSatisfy(\.isMeasured))
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tick != .none ? CleanerTint.warning.opacity(0.10)
                                : Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
