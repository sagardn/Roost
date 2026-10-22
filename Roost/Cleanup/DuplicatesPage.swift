import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// Identical files, a set at a time, and which copies to let go.
///
/// The finding is `Duplicates`; this is the choosing. It starts with nothing
/// ticked, because which copy to keep is the whole decision and a default
/// would be making it. Two buttons make the usual choice in one click --
/// keep the oldest of each set, or the newest -- and the one rule is held at
/// every step: a tick that would leave a set with no copy is refused, and the
/// move to the Bin checks it again against the disk.
final class DuplicatesModel: ObservableObject {

    enum Phase: Equatable { case idle, scanning, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var groups: [Duplicates.Group] = []
    @Published private(set) var filesSeen = 0
    @Published private(set) var isComplete = true
    @Published var selected: Set<URL> = []
    /// Said for a moment when a tick was refused, so the refusal is not a
    /// click that silently did nothing.
    @Published private(set) var refusal: URL?
    @Published private(set) var note: String?

    let home = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var roots: [URL]
    /// New for each scan, for the reason given on the Check-up's.
    private var stop = ScanStop()

    init() { roots = LargeFiles.defaultRoots(home: home) }

    /// A comparison the Check-up made, handed over when its advice sends
    /// somebody here -- a second walk of the same folders a minute later
    /// would find the same sets.
    static var offered: Duplicates.Scan?

    /// On showing the page: take the Check-up's comparison if one was
    /// handed over, but only while every file in it is still as the
    /// comparison saw it -- Large files, Finder or the person may have moved
    /// one since. Otherwise the start screen; nothing is read until asked.
    func appear() {
        guard let scan = Self.offered else { return }
        Self.offered = nil
        guard phase != .scanning, scan.isComplete,
              scan.groups.allSatisfy({ $0.files.allSatisfy(Duplicates.isUnchanged) }) else { return }
        adopt(scan)
        selected = []
    }

    var chosen: [Duplicates.File] { groups.flatMap(\.files).filter { selected.contains($0.url) } }

    /// What trashing the ticked copies gives back: nothing for a clone whose
    /// twin stays, a file's worth otherwise.
    var chosenBytes: Int64 { groups.reduce(0) { $0 + $1.freed(by: selected) } }

    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    func adopt(_ scan: Duplicates.Scan) {
        groups = scan.groups
        filesSeen = scan.filesSeen
        isComplete = scan.isComplete
        phase = .done
    }

    func scan() {
        guard phase != .scanning else { return }
        let stop = ScanStop()
        self.stop = stop
        phase = .scanning
        filesSeen = 0
        note = nil
        let roots = self.roots
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Two minutes, not the Check-up's twenty seconds: this window
            // exists for the person who wants the whole answer.
            let scan = Duplicates.scan(roots: roots, deadline: Date().addingTimeInterval(120),
                                       shouldStop: { stop.isSet },
                                       progress: { seen in
                                           DispatchQueue.main.async { [weak self] in self?.filesSeen = seen }
                                       })
            DispatchQueue.main.async { [weak self] in
                guard let self, !stop.isSet, stop === self.stop else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    self.adopt(scan)
                    self.selected = []
                }
            }
        }
    }

    func cancel() {
        stop.set(true)
        if phase == .scanning { phase = groups.isEmpty ? .idle : .done }
    }

    /// Folders of the person's choosing -- another disk, a photo export.
    /// The open panel is also what grants Roost access to a folder outside
    /// home, so nothing is asked for that was not chosen.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = localized("Compare")
        panel.message = localized("Choose the folders to look for identical files in.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        roots = panel.urls
        phase = .idle
        groups = []
        selected = []
        scan()
    }

    // MARK: Choosing

    func toggle(_ file: Duplicates.File) {
        if selected.contains(file.url) {
            selected.remove(file.url)
            return
        }
        var next = selected
        next.insert(file.url)
        guard Duplicates.keepsACopyOfEach(next, in: groups) else {
            NSSound.beep()
            withAnimation { refusal = file.url }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.refusal == file.url { withAnimation { self?.refusal = nil } }
            }
            return
        }
        selected = next
    }

    func selectSpares(keeping keep: Duplicates.Keep) {
        var next = Set<URL>()
        for group in groups { next.formUnion(Duplicates.spares(in: group, keeping: keep)) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = next }
    }

    func clear() { withAnimation { selected = [] } }

    // MARK: Acting

    func moveChosenToBin() {
        let files = chosen
        guard !files.isEmpty, Duplicates.keepsACopyOfEach(selected, in: groups) else { return }
        Alert.show(localized("Move %0 copies to the Bin?", String(files.count)),
                   localized("One copy of every set stays where it is. A copy that changed since the comparison is left alone.")
                   + "\n\n" + localized("The space comes back when the Bin is emptied."),
                   style: .warning, actionTitle: localized("Move to Bin")) { [weak self] in
            self?.perform(files)
        }
    }

    private func perform(_ files: [Duplicates.File]) {
        var moved: [URL] = []
        var left: [URL] = []
        var bytes: Int64 = 0
        // Exactly what the confirmation counted, not whatever is ticked now.
        let confirmed = Set(files.map(\.url))
        for group in groups {
            let going = group.files.filter { confirmed.contains($0.url) }
            guard !going.isEmpty else { continue }
            // The copy that stays must still be there and still the same, or
            // the set is left exactly as it is: trashing the spares of a file
            // that has itself been edited or deleted is how the last copy goes.
            let staying = group.files.filter { !confirmed.contains($0.url) }
            guard staying.contains(where: Duplicates.isUnchanged) else {
                left += going.map(\.url)
                continue
            }
            var movedHere = Set<URL>()
            for file in going {
                guard Duplicates.isUnchanged(file) else { left.append(file.url); continue }
                do {
                    _ = try CheckUp.trashItem(file.url)
                    moved.append(file.url)
                    movedHere.insert(file.url)
                    Log.info("Duplicates: moved \(file.url.path) to the Bin")
                } catch {
                    left.append(file.url)
                    Log.error("Duplicates: could not move \(file.url.path): \(error.localizedDescription)")
                }
            }
            bytes += group.freed(by: movedHere)
        }
        CheckUpModel.lastMove = Date()
        let gone = Set(moved)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            groups = groups.compactMap { group in
                let kept = group.files.filter { !gone.contains($0.url) }
                return kept.count > 1 ? Duplicates.Group(files: kept) : nil
            }
            selected.subtract(gone)
            var parts = [localized("%0 copies, %1, moved to the Bin.", String(moved.count),
                                   Readings.size(UInt64(bytes)))]
            if !left.isEmpty {
                parts.append(localized("%0 left where they were: they changed after the comparison.",
                                       String(left.count)))
            }
            note = parts.joined(separator: " ")
        }
    }
}

// MARK: - Views

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    /// The copy Quick Look is showing, and the set it pages through with the
    /// arrow keys. Every copy is identical, so the set is for checking where
    /// each one is, not what it holds.
    @State private var previewing: URL?
    @State private var previewSet: [URL] = []

    var body: some View {
        ZStack {
            switch model.phase {
            case .idle:
                ToolHero(symbol: "doc.on.doc.fill", tint: .teal, title: localized("Duplicates"),
                         text: localized("Files stored more than once in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte."),
                         note: localized("Nothing is ticked for you, and one copy of every set always stays."),
                         button: localized("Compare files"),
                         secondary: (localized("Choose folders…"), { model.chooseFolders() })) { model.scan() }
            case .scanning:
                VStack(spacing: 14) {
                    ScanRing(progress: 0, tint: CleanerTint.calm, lineWidth: 10, scanning: true)
                        .frame(width: 150, height: 150)
                    Text(localized("%0 files looked at", model.filesSeen.formatted()))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Text(localized("Files are compared byte for byte. Nothing is moved while Roost looks."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Button(localized("Stop")) { model.cancel() }.keyboardShortcut(.cancelAction)
                }
            case .done:
                results
            }
        }
        .padding(.top, ToolPages.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.appear() }
        .quickLookPreview($previewing, in: previewSet)
    }

    /// A name and a hash say nothing about whether a file is the photo you
    /// want gone or the one you want kept. Quick Look shows it, in the
    /// system's own panel, without opening any app.
    private func preview(_ url: URL, in group: Duplicates.Group) {
        previewSet = group.files.map(\.url)
        previewing = url
    }

    private var results: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.groups.isEmpty
                         ? localized("No identical files found")
                         : localized("%0 sets of identical files, %1 in spare copies",
                                     String(model.groups.count),
                                     Readings.size(UInt64(model.totalReclaimable))))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    Button(localized("Choose folders…")) { model.chooseFolders() }
                    Button(localized("Compare again")) { model.scan() }
                }
                Text(localized("In %0. Files over 1 MB, compared byte for byte; apps and developer project folders are left out.",
                               model.roots.map(\.lastPathComponent).joined(separator: ", ")))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isComplete {
                    Text(localized("Stopped at the time limit; there may be more."))
                        .font(.system(size: 11.5)).foregroundStyle(CleanerTint.warning)
                }
                if let note = model.note {
                    Text(note).font(.system(size: 12)).foregroundStyle(CleanerTint.calm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.groups.isEmpty {
                    HStack(spacing: 8) {
                        Text(localized("Select the spares:")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Button(localized("Keep the oldest")) { model.selectSpares(keeping: .oldest) }
                        Button(localized("Keep the newest")) { model.selectSpares(keeping: .newest) }
                        Button(localized("Clear")) { model.clear() }.disabled(model.selected.isEmpty)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 12)
            Divider().opacity(0.6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.groups, id: \.files.first?.url) { group in
                        GroupCard(group: group, model: model) { preview($0, in: group) }
                    }
                }
                .padding(14)
            }
            Divider().opacity(0.6)
            HStack {
                if !model.chosen.isEmpty {
                    Text(localized("%0 selected · %1", String(model.chosen.count),
                                   Readings.size(UInt64(model.chosenBytes))))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                GlowButton(title: localized("Move to Bin"), symbol: "trash", tint: CleanerTint.critical,
                           compact: true, enabled: !model.chosen.isEmpty) { model.moveChosenToBin() }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
        }
    }
}

private struct GroupCard: View {
    let group: Duplicates.Group
    @ObservedObject var model: DuplicatesModel
    let preview: (URL) -> Void

    @State private var hoveringThumbnail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The thumbnail is the first place anyone clicks to see a
                // file, so it previews, with an eye on hover to say it does.
                Button { preview(group.files[0].url) } label: {
                    Thumbnail(url: group.files[0].url)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "eye.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                                .opacity(hoveringThumbnail ? 1 : 0))
                }
                .buttonStyle(.plain)
                .onHover { hoveringThumbnail = $0 }
                .help(localized("Preview"))
                .accessibilityLabel(localized("Preview"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.files[0].name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(localized("%0 copies of %1 · %2 to gain", String(group.files.count),
                                   Readings.size(UInt64(group.length)),
                                   Readings.size(UInt64(group.reclaimable))))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { preview(group.files[0].url) } label: {
                    Label(localized("Preview"), systemImage: "eye")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(group.files, id: \.url) { file in
                CopyRow(file: file, group: group, model: model) { preview(file.url) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

private struct CopyRow: View {
    let file: Duplicates.File
    let group: Duplicates.Group
    @ObservedObject var model: DuplicatesModel
    let preview: () -> Void

    private var isOn: Bool { model.selected.contains(file.url) }

    private var folder: String {
        let parent = file.url.deletingLastPathComponent().path
        let home = model.home.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggle(file) } label: {
                HStack(spacing: 10) {
                    CheckCircle(tick: isOn ? .all : .none, tint: CleanerTint.critical)
                    // The name and the folder both: copies differ by either,
                    // and `tmp_manager` beside `tmp_manager.exe` in one folder
                    // read as the same row twice when only the folder showed.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 0) {
                            Text(folder).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                            Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            Text(file.modified, style: .date).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            if !group.freesSpace(file) {
                                Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                // A clone shares its blocks: moving it alone
                                // gives nothing back, and the figure says so.
                                Text(localized("a clone: removing it frees no space"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: .roostBlue))
                            }
                            if model.refusal == file.url {
                                Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                Text(localized("one copy always stays"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(CleanerTint.warning)
                                    .transition(.opacity)
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.url.path)
            .accessibilityValue(isOn ? localized("Selected") : localized("Not selected"))
            // Its own button beside the row's, never part of it: a click on
            // the row ticks the copy, and looking at a file must not.
            Button(action: preview) {
                Image(systemName: "eye").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(localized("Preview"))
            .accessibilityLabel(localized("Preview"))
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(localized("Reveal in Finder"))
            .accessibilityLabel(localized("Reveal in Finder"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? CleanerTint.critical.opacity(0.10) : Color.clear))
    }
}

/// Quick Look's own thumbnail of a file, so a set of identical photos shows
/// the photo. Falls back to the file's Finder icon while it is made, or when
/// Quick Look has nothing for it.
struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72),
                                                           scale: 2, representationTypes: .thumbnail)
                if let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    image = made.nsImage
                }
            }
    }
}
