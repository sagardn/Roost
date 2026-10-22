import AppKit
import SwiftUI

/// Where the space went: a folder drawn as rectangles in proportion to what
/// is in it, with the same children listed beside it by size.
///
/// The map is for finding and the list is for reading -- a rectangle says
/// "this is most of it" at a glance, and a row says exactly how much and
/// what it is called. Click a folder in either to go into it.
///
/// Rows can be ticked and moved to the Bin, which the page first did not
/// allow: finding the 47 GB folder and then having to go and find it again
/// in Finder to remove it was the step everybody took next. What can be
/// ticked is `SpaceMap.isRemovable` -- the home folder's own folders,
/// ~/Library and everything outside home but other disks are not -- and
/// each entry is checked against the disk again before it moves.
final class SpaceMapModel: ObservableObject {

    enum Phase: Equatable { case idle, scanning, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var map: SpaceMap.Result?
    @Published private(set) var progress = SpaceMap.Progress()
    /// The folder being shown, somewhere inside the map.
    @Published private(set) var current: URL
    @Published private(set) var root: URL
    @Published var hovered: URL?
    @Published private(set) var opening: URL?
    /// Ticked entries, by standardised URL, as they were measured.
    @Published private(set) var selected: [URL: SpaceMap.Node] = [:]
    @Published private(set) var volume: Volume?

    /// The disk the mapped folder is on, for the bar above the map: a
    /// folder's size means little until it is set against the disk's.
    struct Volume: Equatable {
        let name: String
        let total: Int64
        let available: Int64
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    private var stop = ScanStop()
    /// Which walk the map on screen came from. A folder opened during one
    /// walk must not land in the map of another.
    private var generation = 0

    /// `root` is for `--render spacemap:`, which maps a small folder rather
    /// than wait a minute for a home folder.
    init(root: URL? = nil) {
        let start = root ?? FileManager.default.homeDirectoryForCurrentUser
        self.root = start
        current = start
    }

    var node: SpaceMap.Node? { map.flatMap { SpaceMap.node(at: current, in: $0.root) } }

    /// From the map's root down to the folder shown, for the path bar.
    var trail: [SpaceMap.Node] {
        guard let map else { return [] }
        var out: [SpaceMap.Node] = [map.root]
        var here = map.root
        let target = current.standardizedFileURL.path
        while here.url.standardizedFileURL.path != target,
              let next = here.children.first(where: {
                  $0.isFolder && (target == $0.url.standardizedFileURL.path
                                  || target.hasPrefix($0.url.standardizedFileURL.path + "/"))
              }) {
            out.append(next)
            here = next
        }
        return out
    }

    func scan() {
        guard phase != .scanning else { return }
        let stop = ScanStop()
        self.stop = stop
        generation += 1
        phase = .scanning
        progress = SpaceMap.Progress()
        let root = self.root
        let home = self.home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Two minutes. A 64 GB home folder took 48 s here -- `du` takes
            // 43 s over the same tree, so the walk is near the floor for
            // asking the file system about every file one at a time.
            let map = SpaceMap.scan(root, home: home, deadline: Date().addingTimeInterval(120),
                                    shouldStop: { stop.isSet },
                                    progress: { report in
                                        DispatchQueue.main.async { [weak self] in self?.progress = report }
                                    })
            DispatchQueue.main.async { [weak self] in
                guard let self, stop === self.stop else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    self.map = map
                    self.current = root
                    self.selected = [:]
                    self.volume = Self.volume(of: root)
                    self.phase = .done
                }
            }
        }
    }

    /// Stops the walk. What it found so far is drawn, marked partial --
    /// stopping is how somebody gets an answer for the part they care about
    /// without waiting for the rest.
    func cancel() { stop.set(true) }

    func open(_ node: SpaceMap.Node) {
        guard node.isFolder else { return }
        guard node.isCollapsed, map != nil else {
            withAnimation(.easeOut(duration: 0.2)) { current = node.url }
            return
        }
        // Too small to have been kept: walk just this folder now.
        opening = node.url
        let home = self.home
        let started = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let walked = SpaceMap.scan(node.url, home: home, deadline: Date().addingTimeInterval(30))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.opening == node.url { self.opening = nil }
                // Into the map as it is now, and only if it is still the map
                // this folder was opened in: a rescan or another folder chosen
                // meanwhile has its own tree, and the old one must not replace it.
                guard self.generation == started, let current = self.map?.root else { return }
                var replacement = walked.root
                replacement.name = node.name
                self.map?.root = SpaceMap.replacing(node.url, with: replacement, in: current)
                withAnimation(.easeOut(duration: 0.2)) { self.current = node.url }
            }
        }
    }

    func go(to url: URL) { withAnimation(.easeOut(duration: 0.2)) { current = url } }

    // MARK: Removing

    func canSelect(_ node: SpaceMap.Node) -> Bool {
        SpaceMap.isRemovable(node, root: root, home: home)
    }

    func isSelected(_ node: SpaceMap.Node) -> Bool { selected[node.url.standardizedFileURL] != nil }

    func toggle(_ node: SpaceMap.Node) {
        let key = node.url.standardizedFileURL
        if selected[key] != nil {
            selected[key] = nil
        } else if canSelect(node) {
            selected[key] = node
        }
    }

    func selectNone() { selected = [:] }

    /// What would actually move: a folder ticked along with something in it
    /// is one entry, and counted once.
    var chosen: [SpaceMap.Node] {
        SpaceMap.collapsed(Set(selected.keys)).compactMap { selected[$0] }
    }

    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }

    func review() {
        let items = chosen
        guard !items.isEmpty else { return }
        let bytes = Readings.size(UInt64(chosenBytes))
        Alert.show(localized("Move %0 to the Bin?", bytes),
                   localized("%0 items, %1, go to the Bin. Anything that changed since the scan is left where it is.",
                             String(items.count), bytes)
                   + "\n\n" + localized("The space comes back when the Bin is emptied."),
                   style: .warning, actionTitle: localized("Move to Bin")) { [weak self] in
            self?.perform(items)
        }
    }

    private func perform(_ items: [SpaceMap.Node]) {
        var removal = LargeFiles.Removal()
        for node in items {
            // Measured minutes ago, perhaps: a file written to since, or an
            // entry that is gone, is left alone and counted as not moved.
            guard SpaceMap.isUnchanged(node) else {
                removal.failed.append(node.url)
                if removal.reason == nil { removal.reason = localized("it changed after the scan; scan again to see it") }
                continue
            }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                removal.moved.append(node.url.standardizedFileURL)
                removal.bytesFreed += node.bytes
            } catch {
                removal.failed.append(node.url)
                if removal.reason == nil { removal.reason = LargeFiles.reason(for: error) }
            }
        }
        if !removal.moved.isEmpty {
            CheckUpModel.lastMove = Date()
            if let root = map?.root {
                withAnimation(.easeOut(duration: 0.25)) {
                    map?.root = SpaceMap.removing(Set(removal.moved), from: root)
                }
            }
        }
        selected = [:]
        volume = Self.volume(of: root)
        Notify.show(removal.failed.isEmpty
                        ? localized("%0 items, %1, moved to the Bin.", String(removal.moved.count),
                                    Readings.size(UInt64(removal.bytesFreed)))
                        : LargeFiles.message(for: removal),
                    symbol: "trash")
    }

    private static func volume(of url: URL) -> Volume? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]), let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return Volume(name: values.volumeName ?? url.lastPathComponent,
                      total: Int64(total),
                      available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    func up() {
        guard current.standardizedFileURL != root.standardizedFileURL else { return }
        go(to: current.deletingLastPathComponent())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = localized("Map")
        panel.message = localized("Choose a folder or a disk to map.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        current = url
        map = nil
        selected = [:]
        stop.set(true)
        phase = .idle
        scan()
    }
}

// MARK: - Views

struct SpaceMapView: View {
    @ObservedObject var model: SpaceMapModel

    var body: some View {
        if model.phase == .idle {
            ToolHero(symbol: "square.grid.3x3.square", tint: .blue, title: localized("Space map"),
                     text: localized("Every folder drawn by size, so you can see where the space went and open what holds it."),
                     note: localized("A large home folder takes about as long as Finder's Get Info."),
                     button: localized("Map home folder"),
                     secondary: (localized("Choose folder…"), { model.chooseFolder() })) { model.scan() }
                .padding(.top, ToolPages.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            map
        }
    }

    private var map: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, ToolPages.top).padding(.bottom, 10)
            if let volume = model.volume {
                DiskBar(volume: volume, folder: model.node?.bytes ?? 0, selected: model.chosenBytes)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider().opacity(0.6)
            switch model.phase {
            case .idle, .scanning:
                scanning
            case .done:
                if let node = model.node {
                    HStack(spacing: 0) {
                        MapCanvas(node: node, model: model)
                            .padding(10)
                        Divider().opacity(0.6)
                        ChildList(node: node, model: model).frame(width: 260)
                    }
                    Divider().opacity(0.6)
                    HStack(spacing: 12) {
                        notes
                        selection
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.up() } label: { Image(systemName: "chevron.left") }
                .disabled(model.current.standardizedFileURL == model.root.standardizedFileURL)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help(localized("Enclosing folder"))
                .accessibilityLabel(localized("Enclosing folder"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.trail.enumerated()), id: \.element.url) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button(node.name) { model.go(to: node.url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: index == model.trail.count - 1 ? .semibold : .regular))
                    }
                }
            }
            Spacer()
            if let node = model.node {
                Text(Readings.size(UInt64(node.bytes)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Button(localized("Choose folder…")) { model.chooseFolder() }
            Button(localized("Map again")) { model.scan() }.disabled(model.phase == .scanning)
        }
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ScanRing(progress: 0, tint: CleanerTint.calm, lineWidth: 10, scanning: true)
                .frame(width: 150, height: 150)
            Text(localized("%0 files, %1", model.progress.files.formatted(),
                           Readings.size(UInt64(model.progress.bytes))))
                .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
            Text(model.progress.folder).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360)
            Text(localized("A large home folder takes about as long as Finder's Get Info. Stop to see what was found so far."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(localized("Stop")) { model.cancel() }.keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The running total and the one button that acts on it. Not drawn until
    /// something is ticked: a red button over an empty selection is a
    /// question nobody has asked yet.
    @ViewBuilder
    private var selection: some View {
        if !model.selected.isEmpty {
            Text(localized("%0 selected · %1", String(model.chosen.count),
                           Readings.size(UInt64(model.chosenBytes))))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .fixedSize()
            Button(localized("Select none")) { model.selectNone() }
            Button { model.review() } label: {
                Label(localized("Move to Bin"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(CleanerTint.critical)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    @ViewBuilder
    private var notes: some View {
        let map = model.map
        HStack(spacing: 14) {
            if map?.root.isPartial == true {
                Label(localized("Stopped before the end: the figures are for what was reached."),
                      systemImage: "hourglass").foregroundStyle(CleanerTint.warning)
            }
            if let unreadable = map?.root.unreadable, unreadable > 0 {
                HStack(spacing: 6) {
                    Label(localized("%0 folders could not be opened and are not counted.", unreadable.formatted()),
                          systemImage: "lock")
                        .help(localized("macOS protects some folders, such as Mail and Messages, from other apps."))
                    // The way to count them, next to the count of them.
                    Button(localized("Allow Full Disk Access…")) { SettingsLink.fullDiskAccess.open() }
                        .buttonStyle(.link)
                }
            }
            if let skipped = map?.notMeasured, !skipped.isEmpty {
                // Named by what they hold: "Containers, Group Containers"
                // were the folder names, and meant nothing to most people.
                Label(localized("Apps' private data is not measured: looking inside asks for permission once for every app."),
                      systemImage: "eye.slash")
                    .help(skipped.map(\.path).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .lineLimit(2)
    }
}

/// The colour of a rectangle: what it is, not how big. Files take the colour
/// their category has in the Disk Cleaner, so a video is the same magenta in
/// both windows; folders the accent colour; what cannot be opened, grey.
private func colour(of node: SpaceMap.Node) -> Color {
    switch node.kind {
    case .folder:            return Color.accentColor
    case .package:           return Color.accentColor.opacity(0.6)
    case .file:              return CleanerTint.of(LargeFiles.Category.of(node.url))
    case .smaller:           return Color(nsColor: .tertiaryLabelColor)
    case .unreadable, .skipped: return Color(nsColor: .quaternaryLabelColor)
    }
}

private func label(of node: SpaceMap.Node) -> String {
    if case .smaller(let count) = node.kind { return localized("%0 smaller items", String(count)) }
    return node.name
}

private struct MapCanvas: View {
    let node: SpaceMap.Node
    @ObservedObject var model: SpaceMapModel

    var body: some View {
        GeometryReader { geometry in
            let children = node.children.filter { $0.bytes > 0 }
            let rects = SpaceMap.squarify(children.map { Double($0.bytes) },
                                          in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(children, rects)), id: \.0.url) { child, rect in
                    Tile(node: child, rect: rect, model: model)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Space map of %0", node.name))
        .accessibilityHint(localized("The list beside the map has the same items."))
    }
}

private struct Tile: View {
    let node: SpaceMap.Node
    let rect: CGRect
    @ObservedObject var model: SpaceMapModel

    var body: some View {
        let hovered = model.hovered == node.url
        let shownRect = rect.insetBy(dx: min(1, rect.width / 4), dy: min(1, rect.height / 4))
        RoundedRectangle(cornerRadius: min(5, shownRect.width / 4, shownRect.height / 4), style: .continuous)
            .fill(colour(of: node).opacity(hovered ? 0.95 : (node.isFolder ? 0.7 : 0.55)))
            .overlay(alignment: .topLeading) {
                if shownRect.width > 70, shownRect.height > 30 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label(of: node)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(Readings.size(UInt64(node.bytes))).font(.system(size: 10)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .padding(5)
                }
            }
            .overlay {
                if model.isSelected(node) {
                    RoundedRectangle(cornerRadius: min(5, shownRect.width / 4, shownRect.height / 4),
                                     style: .continuous)
                        .strokeBorder(CleanerTint.critical, lineWidth: 2)
                }
            }
            .overlay {
                if model.opening == node.url { ProgressView().controlSize(.small) }
            }
            .frame(width: max(0, shownRect.width), height: max(0, shownRect.height))
            .offset(x: shownRect.minX, y: shownRect.minY)
            .onHover { inside in
                if inside { model.hovered = node.url } else if model.hovered == node.url { model.hovered = nil }
            }
            .onTapGesture { model.open(node) }
            .help(label(of: node) + " — " + Readings.size(UInt64(node.bytes)))
            .contextMenu {
                Button(localized("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                    .disabled(!FileManager.default.fileExists(atPath: node.url.path))
                if model.canSelect(node) {
                    Toggle(localized("Selected"), isOn: Binding(get: { model.isSelected(node) },
                                                                set: { _ in model.toggle(node) }))
                }
            }
    }
}

private struct ChildList: View {
    let node: SpaceMap.Node
    @ObservedObject var model: SpaceMapModel

    /// What is in the folder, counting a "smaller items" entry as the
    /// items it stands for.
    private var itemCount: Int {
        node.children.reduce(0) { count, child in
            if case .smaller(let inner) = child.kind { return count + inner }
            return count + 1
        }
    }

    var body: some View {
        ScrollView {
            HStack(spacing: 10) {
                NodeIcon(node: node, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(localized("%0 items, %1 in total", String(itemCount),
                                   Readings.size(UInt64(node.bytes))))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(node.children, id: \.url) { child in
                    ChildRow(child: child, share: node.bytes > 0 ? Double(child.bytes) / Double(node.bytes) : 0,
                             model: model)
                }
            }
            .padding(8)
        }
    }
}

private struct ChildRow: View {
    let child: SpaceMap.Node
    let share: Double
    @ObservedObject var model: SpaceMapModel

    private var sizeText: String {
        switch child.kind {
        case .unreadable: return localized("No access")
        case .skipped:    return localized("Not measured")
        default:          return Readings.size(UInt64(child.bytes))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Kept in place, invisible, where a row cannot be ticked, so the
            // icons below still line up in one column.
            Toggle("", isOn: Binding(get: { model.isSelected(child) },
                                     set: { _ in model.toggle(child) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .opacity(model.canSelect(child) ? 1 : 0)
                .disabled(!model.canSelect(child))
                .accessibilityLabel(label(of: child))
                .accessibilityHidden(!model.canSelect(child))
            // A folder opens; a file has nowhere to open to, so a click on its
            // row ticks it. It used to be a disabled button, which greyed every
            // file out as if it were unavailable.
            Button { child.isFolder ? model.open(child) : model.toggle(child) } label: {
                HStack(spacing: 8) {
                    NodeIcon(node: child, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(of: child)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        GeometryReader { geometry in
                            Capsule().fill(colour(of: child).opacity(0.6))
                                .frame(width: geometry.size.width * CGFloat(max(0.01, min(1, share))))
                        }
                        .frame(height: 3)
                    }
                    Spacer(minLength: 4)
                    Text(sizeText).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    if child.isFolder {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!child.isFolder && !model.canSelect(child))
            Button { NSWorkspace.shared.activateFileViewerSelecting([child.url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help(localized("Reveal in Finder"))
            .accessibilityLabel(localized("Reveal in Finder"))
            .disabled({ if case .smaller = child.kind { return true }; return false }())
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(model.hovered == child.url ? Color.primary.opacity(0.07) : .clear))
        .onHover { inside in
            if inside { model.hovered = child.url } else if model.hovered == child.url { model.hovered = nil }
        }
    }
}

/// The icon Finder shows for an entry, so a ZIP, a movie and a folder are
/// told apart before their names are read. Entries that are not one thing
/// on disk -- "smaller items", a folder that could not be read -- keep the
/// map's colour, which is what ties a row to its rectangle.
private struct NodeIcon: View {
    let node: SpaceMap.Node
    let size: CGFloat

    /// `icon(forFile:)` is a Launch Services lookup, and the list redraws on
    /// every hover change -- up to forty of them each time without this.
    private static let cache = NSCache<NSString, NSImage>()

    private var image: NSImage? {
        switch node.kind {
        case .file, .folder, .package:
            let key = node.url.path as NSString
            if let hit = Self.cache.object(forKey: key) { return hit }
            let icon = NSWorkspace.shared.icon(forFile: node.url.path)
            Self.cache.setObject(icon, forKey: key)
            return icon
        case .smaller, .unreadable, .skipped:
            return nil
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size / 5).fill(colour(of: node))
                    .padding(size / 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The disk the map is on: how full, and how much of it is the folder shown
/// and what is ticked in it. The folder's share is drawn inside the used
/// part, the ticked share inside that, so the three read as one measure.
private struct DiskBar: View {
    let volume: SpaceMapModel.Volume
    let folder: Int64
    let selected: Int64

    private func share(_ bytes: Int64) -> CGFloat {
        CGFloat(max(0, min(1, Double(bytes) / Double(max(1, volume.total)))))
    }

    var body: some View {
        let used = volume.total - volume.available
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(volume.name, systemImage: "internaldrive").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(localized("%0 free of %1", Readings.size(UInt64(max(0, volume.available))),
                               Readings.size(UInt64(volume.total))))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.22)).frame(width: width * share(used))
                    Capsule().fill(Color.accentColor).frame(width: width * share(folder))
                    if selected > 0 {
                        Capsule().fill(CleanerTint.critical).frame(width: max(3, width * share(selected)))
                    }
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.2), value: selected)
        }
        .accessibilityElement(children: .combine)
    }
}
