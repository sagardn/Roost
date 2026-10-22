import SwiftUI

/// The Storage panel: how full the watched volume is, as a ring with the
/// figures beside it, what the disk is doing now, and how long since the Mac
/// started.
///
/// Its own full-width row under the cards rather than a fourth card. A ring
/// whose centre carries "84%" and "used" legibly wants about 130pt, and the
/// breakdown beside it another 200; a grid cell is 220 wide at the window's
/// narrowest, which would have meant a ring squeezed to a badge or the
/// figures pushed underneath it. The cards above keep their row.
struct StoragePanel: View {
    let state: DashboardModel.CardState
    let uptime: String
    /// The page's width, which decides between one row and two.
    let width: CGFloat
    /// Every partition on every drive, read here rather than by the Disk
    /// module: it changes when something mounts, not on the tick.
    @StateObject private var partitions = PartitionList()
    let open: () -> Void
    let enable: () -> Void

    var body: some View {
        if case .reading(let report) = state, report.unavailable == nil, let storage = report.storage {
            reading(report, storage)
        } else {
            // Off, not sampled, starting: the same card, with the same one
            // control that would give it a reading, as any other module.
            MetricCard(card: .disk, state: state, open: open, enable: enable)
        }
    }

    /// The width the one-row layout needs: ring and breakdown about 430,
    /// activity 230, uptime 200, plus dividers and padding -- measured from
    /// the 1400pt render.
    static let rowWidth: CGFloat = 960

    private func reading(_ report: DashboardReport, _ storage: StorageDetail) -> some View {
        let tone = StatusTone(report.severity)
        // One row where there is room; otherwise the volume keeps the full
        // width and activity and uptime share a row beneath it.
        //
        // Chosen from the page's width, not by ViewThatFits: that measured
        // the row as fitting at 1100pt, where the uptime caption then ran
        // off the panel's edge.
        return VStack(alignment: .leading, spacing: 14) {
            Group {
            if width >= Self.rowWidth {
                // Activity and uptime capped, the volume taking the rest: left
                // to the layout, the activity section took every spare point
                // and its chart drifted away from its figures. No
                // layoutPriority: with it the row handed the volume everything
                // but the others' stated minimums, the uptime caption needed
                // more than its minimum, and the page came out 20pt too wide.
                HStack(alignment: .top, spacing: 18) {
                    volume(report, storage, tone)
                        .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                    Divider()
                    activity(storage).frame(minWidth: 190, maxWidth: 320, alignment: .leading)
                    Divider()
                    started.frame(minWidth: 130, maxWidth: 220, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    volume(report, storage, tone)
                    Divider()
                    HStack(alignment: .top, spacing: 18) {
                        activity(storage).frame(maxWidth: .infinity, alignment: .leading)
                        started.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            }
            ForEach(partitions.drives) { drive in
                Divider()
                PartitionMap(drive: drive, startupTone: tone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .onAppear { partitions.start() }
        .onDisappear { partitions.stop() }
    }

    // MARK: - Volume

    private func volume(_ report: DashboardReport, _ storage: StorageDetail, _ tone: StatusTone) -> some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 18) {
                StorageRing(fraction: storage.usedFraction, tone: tone)
                    .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        GlyphTile(glyph: .named("Disk"), size: 18)
                        Text(DashboardCard.disk.title).font(.headline)
                        StatusBadge(text: report.caption, tone: tone).fixedSize()
                    }
                    Text(storage.volume)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 4) {
                        legend(localized("Used"), Readings.size(storage.used), swatch: tone.color)
                        legend(localized("Available"), Readings.size(storage.free), swatch: StorageRing.freeColor)
                        legend(localized("Capacity"), Readings.size(storage.total), swatch: nil)
                    }
                    .font(.callout)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localized("Open the %0 page", DashboardCard.disk.title))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DashboardCard.disk.title)
        .accessibilityValue(spoken(report, storage))
        .accessibilityHint(localized("Opens the %0 page", DashboardCard.disk.title))
        .accessibilityAddTraits(.isButton)
    }

    /// A row of the breakdown, with the ring's colour beside the figure it
    /// stands for -- so the ring can be read without its colours, and the
    /// colours without the ring.
    private func legend(_ label: String, _ value: String, swatch: Color?) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swatch ?? .clear)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(value)
                .monospacedDigit()
        }
    }

    private func spoken(_ report: DashboardReport, _ storage: StorageDetail) -> String {
        let used = storage.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return [localized("%0 used", used), report.caption, storage.volume,
                "\(localized("Used")) \(Readings.size(storage.used))",
                "\(localized("Available")) \(Readings.size(storage.free))",
                "\(localized("Capacity")) \(Readings.size(storage.total))"].joined(separator: ", ")
    }

    // MARK: - Activity

    /// Write above read, ↑ over ↓, as in the Disk popup, its menu bar shape
    /// and its traffic chart: the order that module settled on after a
    /// version that put reads on top under the write arrow.
    private func activity(_ storage: StorageDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(localized("Disk activity"), symbol: "arrow.up.arrow.down")
            if let read = storage.readRate, let write = storage.writeRate {
                VStack(alignment: .leading, spacing: 4) {
                    rate(localized("Write"), "↑ " + Readings.rate(write), swatch: StatusTone.warning.color)
                    rate(localized("Read"), "↓ " + Readings.rate(read), swatch: StatusTone.calm.color)
                }
                .font(.callout)
                Sparkline(values: storage.readHistory, mirror: storage.writeHistory, height: 30)
            } else {
                Text(localized("Measuring…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rate(_ label: String, _ value: String, swatch: Color) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(swatch).frame(width: 9, height: 3).accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
            Text(value).monospacedDigit().lineLimit(1)
        }
    }

    // MARK: - Uptime

    private var started: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(localized("Uptime"), symbol: "clock")
            Text(uptime)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let boot = DeviceInfo.bootDate {
                Text(localized("Since %0", boot.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The ring: used in its severity colour, available as the track, and the
/// percentage used in the middle.
///
/// Drawn, not imported: two circles, one trimmed to the fraction. It moves
/// only when the fraction does -- a disk changes over minutes, so there is
/// nothing to animate the rest of the time -- and not at all under Reduce
/// Motion.
struct StorageRing: View {
    let fraction: Double?
    let tone: StatusTone

    /// The available part. Neutral rather than a fourth colour: a disk's
    /// free space is not a state, and the palette's three colours are
    /// states. Strong enough to read as a segment, not as an empty track.
    static let freeColor = Color(nsColor: .tertiaryLabelColor).opacity(0.55)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: Double = 0

    private let lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Self.freeColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: drawn)
                .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(fraction == nil ? localized("Unavailable") : localized("used"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .onAppear { settle() }
        .onChange(of: fraction) { settle() }
        // The panel says the same in words.
        .accessibilityHidden(true)
    }

    private func settle() {
        let target = fraction ?? 0
        if reduceMotion {
            drawn = target
        } else {
            withAnimation(.easeOut(duration: 0.6)) { drawn = target }
        }
    }
}

// MARK: - Partitions

/// The drives' partitions, read off the main thread when the panel appears
/// and again when anything mounts or unmounts -- the only times they can
/// change. About 40 ms a read, measured on this Mac; never on the tick.
final class PartitionList: ObservableObject {
    @Published private(set) var drives: [DiskPartitions.Drive] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        reload()
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            })
        }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    deinit { stop() }

    private func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let drives = DiskPartitions.read()
            DispatchQueue.main.async { self?.drives = drives }
        }
    }
}

/// One drive: a bar of its partitions at their real proportions, and a row
/// for each.
///
/// Usage is shown only where macOS mounts something on the partition. A
/// Linux filesystem macOS has no driver for gets its size and the words
/// saying so, never a guess at how full it is.
struct PartitionMap: View {
    let drive: DiskPartitions.Drive
    let startupTone: StatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(localized("Partitions"), systemImage: "square.split.3x1")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("\(drive.model) · \(Readings.size(drive.size))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            bar
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(drive.partitions) { partition in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(partition))
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(partition.name)
                            .lineLimit(1)
                            .gridColumnAlignment(.leading)
                        // Blank where the name already is the kind -- "Linux
                        // Linux" said it twice.
                        Text(partition.name == partition.kind.title ? "" : partition.kind.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(Readings.size(partition.size))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(usage(partition))
                            .foregroundStyle(partition.used == nil ? .secondary : .primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .help(partition.used == nil && [.linux, .linuxLVM, .linuxSwap].contains(partition.kind)
                          ? localized("macOS has no driver for this file system, so it cannot see how full it is.")
                          : "")
                }
                if drive.unallocated > 0 {
                    GridRow {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, lineWidth: 1)
                            .frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(localized("Unallocated")).foregroundStyle(.secondary)
                        Text("")
                        Text(Readings.size(drive.unallocated)).monospacedDigit()
                        Text("")
                    }
                }
            }
            .font(.callout)
        }
    }

    /// Each partition at its share of the drive, with a point of air between.
    /// A partition too small to see still gets three points, so the 524 MB
    /// ones are there to be found.
    private var bar: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(drive.partitions.count - 1, 0)) * 1
            let usable = max(0, geometry.size.width - gaps)
            HStack(spacing: 1) {
                ForEach(drive.partitions) { partition in
                    Rectangle()
                        .fill(color(partition))
                        .frame(width: max(3, usable * CGFloat(Double(partition.size) / Double(max(drive.size, 1)))))
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// The startup partition in the ring's colour, so the bar and the ring
    /// are visibly the same disk; other systems in their own colours; the
    /// parts macOS keeps for itself quiet.
    private func color(_ partition: DiskPartitions.Partition) -> Color {
        if partition.isStartup { return startupTone.color }
        switch partition.kind {
        case .apfs, .hfs:                    return Color(nsColor: .roostBlue)
        case .linux, .linuxLVM, .linuxSwap:  return Color(nsColor: .roostMagenta)
        case .windows, .efi:                 return Color(nsColor: .roostOlive)
        default:                             return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func usage(_ partition: DiskPartitions.Partition) -> String {
        if let used = partition.used, let free = partition.free {
            return localized("%0 used · %1 free", Readings.size(used), Readings.size(free))
        }
        switch partition.kind {
        case .linux, .linuxLVM, .linuxSwap:
            // Short, so it fits the narrowest window; the row's tooltip says
            // the rest.
            return localized("Not readable by macOS")
        default:
            return localized("Not mounted")
        }
    }
}
