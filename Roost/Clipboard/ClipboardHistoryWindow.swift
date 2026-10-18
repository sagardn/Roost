import AppKit
import SwiftUI

/// The whole clipboard history, in a window of its own.
///
/// A window, not a page of the Settings window: it is somewhere to work --
/// find a thing, look at it, use it -- and it should be able to sit beside
/// the app it is being pasted into. The settings for it are a page of
/// Settings, a click away from the header.
final class ClipboardHistoryWindow: NSWindow, NSWindowDelegate {

    private static var current: ClipboardHistoryWindow?
    private static let frameKey = "com.sagar.roost.ClipboardHistory.WindowFrame"

    private let model = ClipboardHistoryModel()

    /// Opens the window, or brings it forward.
    ///
    /// `target` is the app to paste into if automatic paste is on -- the
    /// one in front before this window took focus. Recorded here because a
    /// moment later the frontmost app is Roost.
    static func present(over target: NSRunningApplication?) {
        let window = current ?? ClipboardHistoryWindow()
        current = window
        if let target { window.model.target = target }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = localized("Clipboard History")
        minSize = NSSize(width: 560, height: 360)
        isReleasedWhenClosed = false
        delegate = self
        let host = NSHostingController(rootView: ClipboardHistoryView(service: .shared, model: model))
        // The window keeps the size it is given. By default a hosting
        // controller sizes its window to the content's minimum, and the
        // first render opened at 560 × 392 -- the floor, not the window.
        host.sizingOptions = []
        contentViewController = host
        setContentSize(NSSize(width: 760, height: 520))
        setFrameAutosaveName(Self.frameKey)
        if !setFrameUsingName(Self.frameKey) { center() }
    }

    func windowWillClose(_ notification: Notification) {
        // Let go, so the next open starts from a fresh selection; the history
        // itself is the service's and does not go anywhere.
        DispatchQueue.main.async { Self.current = nil }
    }
}

/// What the window is showing, apart from the history itself.
final class ClipboardHistoryModel: ObservableObject {
    @Published var query = ""
    @Published var filter: ClipboardHistory.Filter = .all
    @Published var selection: UUID?
    weak var target: NSRunningApplication?
}

extension ClipboardHistory.Filter {
    var title: String {
        switch self {
        case .all:    return localized("All")
        case .text:   return localized("Text")
        case .images: return localized("Images")
        case .pinned: return localized("Pinned")
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var service: ClipboardService
    @ObservedObject var model: ClipboardHistoryModel
    @State private var confirmingClear: Bool?   // true: everything; false: unpinned only
    @FocusState private var listFocused: Bool

    private var entries: [ClipboardEntry] { service.history.matching(model.query, filter: model.filter) }
    private var selected: ClipboardEntry? { model.selection.flatMap(service.history.entry) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 280, idealWidth: 340)
                ClipboardInspector(service: service, entry: selected,
                                   use: { use($0) })
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        // The newest entry selected and the list focused on open, so the
        // inspector is not blank and the keyboard works at once: arrows to
        // move, Return to copy. Focus otherwise fell on the Clear menu.
        .onAppear {
            if model.selection == nil { model.selection = entries.first?.id }
            DispatchQueue.main.async { listFocused = true }
        }
        .onChange(of: model.filter) { keepSelectionVisible() }
        .onChange(of: model.query) { keepSelectionVisible() }
        .confirmationDialog(
            confirmingClear == true ? localized("Clear the whole clipboard history?")
                                    : localized("Clear everything that is not pinned?"),
            isPresented: Binding(get: { confirmingClear != nil }, set: { if !$0 { confirmingClear = nil } })
        ) {
            Button(localized("Clear"), role: .destructive) {
                service.clear(keepingPinned: confirmingClear != true)
                model.selection = nil
                confirmingClear = nil
            }
            Button(localized("Cancel"), role: .cancel) { confirmingClear = nil }
        } message: {
            Text(localized("The entries and their stored images are deleted from this Mac. This cannot be undone."))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Clipboard History"))
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        ClipboardStatusLabel(status: service.status)
                        Text(localized("%0 entries · %1", "\(service.history.entries.count)",
                                       ClipboardFormat.bytes(service.history.byteSize)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if service.status == .off {
                    Button(localized("Turn On…")) { ClipboardActions.enableMonitoring() }
                }
                Menu {
                    Button(localized("Clear Unpinned…")) { confirmingClear = false }
                    Button(localized("Clear All…"), role: .destructive) { confirmingClear = true }
                } label: {
                    Label(localized("Clear"), systemImage: "trash")
                }
                .fixedSize()
                .disabled(service.history.entries.isEmpty)
                .help(localized("Delete history from this Mac"))
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(localized("Clipboard settings"))
                .accessibilityLabel(localized("Clipboard settings"))
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(localized("Search text, apps and image sizes"), text: $model.query)
                        .textFieldStyle(.plain)
                        .onSubmit { listFocused = true }
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help(localized("Clear the search"))
                            .accessibilityLabel(localized("Clear the search"))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .surface(padding: 0)
                Picker(localized("Show"), selection: $model.filter) {
                    ForEach(ClipboardHistory.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let problem = service.problem {
                HStack {
                    StatusBadge(text: problem, tone: .warning)
                    Spacer()
                    Button(localized("Dismiss")) { service.dismissProblem() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, RoostMetrics.pageInset)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    // MARK: - List

    private var list: some View {
        Group {
            if entries.isEmpty {
                ClipboardEmptyState(service: service, hasQuery: !model.query.isEmpty || model.filter != .all)
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(entries) { entry in
                        ClipboardRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu { menu(for: entry) }
                            .onTapGesture(count: 2) { use(entry) }
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                // Return uses the selection, Delete deletes it, Space pins it:
                // the history can be worked through without the pointer.
                .onKeyPress(.return) {
                    if let entry = selected { use(entry) }
                    return .handled
                }
                .onDeleteCommand {
                    if let entry = selected { delete(entry) }
                }
                .onKeyPress(.space) {
                    if let entry = selected { service.setPinned(entry.id, !entry.isPinned) }
                    return .handled
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: ClipboardEntry) -> some View {
        Button(localized("Copy")) { use(entry) }
        if ClipboardSettings.autoPaste, let name = model.target?.localizedName {
            Button(localized("Paste into %0", name)) {
                ClipboardActions.use(entry.id, pasteInto: model.target)
            }
        }
        Button(entry.isPinned ? localized("Unpin") : localized("Pin")) {
            service.setPinned(entry.id, !entry.isPinned)
        }
        if entry.kind == .files, let first = entry.fileURLs?.first.flatMap(URL.init(string:)) {
            Button(localized("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([first]) }
        }
        Divider()
        Button(localized("Delete"), role: .destructive) { delete(entry) }
    }

    // MARK: - Actions

    /// Copy, and paste into the app the window was opened over if that is
    /// switched on. The window stays open: somebody working through the
    /// history may want the next thing too.
    private func use(_ entry: ClipboardEntry) {
        ClipboardActions.use(entry.id, pasteInto: ClipboardSettings.autoPaste ? model.target : nil)
    }

    private func delete(_ entry: ClipboardEntry) {
        // The next one along takes the selection, so pressing Delete again
        // keeps going down the list.
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let rest = entries.filter { $0.id != entry.id }
            model.selection = rest.indices.contains(index) ? rest[index].id : rest.last?.id
        }
        service.delete(entry.id)
    }

    /// A selection the filter or search has hidden moves to the first entry
    /// still shown, so the inspector never describes a row that is not there.
    private func keepSelectionVisible() {
        if !entries.contains(where: { $0.id == model.selection }) { model.selection = entries.first?.id }
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil,
                                        userInfo: ["module": "Clipboard"])
    }
}

// MARK: - Inspector

/// The whole of one entry: its text or image at full size, and what was kept.
struct ClipboardInspector: View {
    @ObservedObject var service: ClipboardService
    let entry: ClipboardEntry?
    let use: (ClipboardEntry) -> Void

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(entry.kind.title, systemImage: entry.kind.symbol)
                        .font(.headline)
                    Spacer()
                    Button {
                        service.setPinned(entry.id, !entry.isPinned)
                    } label: {
                        Image(systemName: entry.isPinned ? "pin.slash" : "pin")
                    }
                    .help(entry.isPinned ? localized("Unpin") : localized("Pin"))
                    .accessibilityLabel(entry.isPinned ? localized("Unpin") : localized("Pin"))
                    Button {
                        service.delete(entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(localized("Delete"))
                    .accessibilityLabel(localized("Delete"))
                    Button(localized("Copy")) { use(entry) }
                        .keyboardShortcut(.defaultAction)
                        .help(localized("Put it back on the clipboard, ready for ⌘V"))
                }
                content(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .surface()
                facts(entry)
            }
            .padding(RoostMetrics.pageInset)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(localized("Select an entry to see all of it"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ entry: ClipboardEntry) -> some View {
        if entry.kind == .image {
            if let image = service.imageURL(entry).flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .accessibilityLabel(ClipboardFormat.title(entry))
            } else {
                Text(localized("The stored image is missing, so this entry cannot be restored."))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                Text(entry.text ?? "")
                    .font(entry.kind == .url ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func facts(_ entry: ClipboardEntry) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row(localized("Copied"), entry.date.formatted(date: .abbreviated, time: .standard))
            if let source = entry.sourceName {
                // Who was in front, which is what can be known -- see
                // ClipboardEntry.sourceBundleID.
                row(localized("In front"), source)
            }
            if let size = entry.pixelSize { row(localized("Size"), size) }
            row(localized("Stored"), ClipboardFormat.bytes(entry.byteSize))
            row(localized("Restores as"), restoresAs(entry))
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// The forms a restore puts back, so a plain-text paste of something that
    /// was formatted is never a surprise.
    private func restoresAs(_ entry: ClipboardEntry) -> String {
        var forms: [String] = []
        switch entry.kind {
        case .files: forms.append(localized("Files"))
        case .image: forms.append(localized("Image"))
        default:     forms.append(localized("Plain text"))
        }
        if entry.payload(ClipboardTypes.rtf) != nil { forms.append("RTF") }
        if entry.payload(ClipboardTypes.html) != nil { forms.append("HTML") }
        if entry.kind == .url { forms.append(localized("Link")) }
        return forms.joined(separator: ", ")
    }
}
