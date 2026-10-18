import AppKit
import SwiftUI

/// The Disk Cleaner: the biggest things in the folders people fill, and a
/// way to put them in the Bin.
///
/// SwiftUI rather than the AppKit list it replaces, because almost all of
/// what changed is motion -- a ring that sweeps while the walk runs, a count
/// that rolls, a list that settles in -- and each of those is a modifier here
/// and a CALayer animation with its own timing bookkeeping there.
///
/// Nothing in it deletes. `LargeFiles.moveToBin` is the only way out, and it
/// trashes rather than removes; see there for why that line does not move.
final class LargeFilesWindow: NSWindow, NSWindowDelegate, ClosableWindow {

    var onClose: (() -> Void)?

    private let model = CleanerModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                   styleMask: [.closable, .titled, .miniaturizable, .resizable,
                               .fullSizeContentView],
                   backing: .buffered, defer: true)

        title = localized("Disk Cleaner")
        titlebarAppearsTransparent = true
        // The hero carries the name in large type; the same words again in
        // the title bar, 200pt above it, read as a stutter.
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self

        contentViewController = NSHostingController(
            rootView: CleanerView(model: model, embedded: false))
        // After the controller, which sizes the window to its content's ideal
        // size -- the minimum, here -- and would otherwise open it cramped.
        setContentSize(NSSize(width: 640, height: 600))
        minSize = NSSize(width: 560, height: 520)
    }

    /// The one on screen, if any.
    ///
    /// Kept so a second click brings the same window forward instead of
    /// opening another, and dropped on close so the next click gets a fresh
    /// scan rather than a list from ten minutes ago.
    ///
    /// Here rather than on `DiskCleanup` because that type is compiled by
    /// disk-test, and naming a window from it drags AppKit and half the view
    /// layer into a suite about arithmetic -- which it did, until this moved.
    private static var open: LargeFilesWindow?

    static func present() {
        if let existing = open {
            existing.show()
            return
        }
        let made = LargeFilesWindow()
        made.onClose = { LargeFilesWindow.open = nil }
        open = made
        made.show()
    }

    func windowWillClose(_ notification: Notification) {
        // A walk left running after its window has gone holds the model and
        // spends a core on a list nobody will see.
        model.cancel()
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }

    /// Shows the window and starts a scan.
    ///
    /// Straight into the scan, not the start screen: somebody who pressed
    /// "Disk Cleaner…" from the Disk page has already said what they want.
    /// The settings page, reached by browsing, starts at the explanation.
    func show() {
        setIsVisible(true)
        makeKeyAndOrderFront(nil)
        center()
        NSApp.activate(ignoringOtherApps: true)
        if model.phase == .idle { model.scan() }
    }
}

// MARK: - Model

/// What the cleaner is doing, shared by the window and the settings page.
final class CleanerModel: ObservableObject {

    enum Phase: Equatable { case idle, scanning, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = LargeFiles.Progress()
    @Published private(set) var found: [LargeFiles.Item] = []
    @Published private(set) var volume: DiskReadings.Volume? = DiskReadings.primary()
    @Published private(set) var elapsed: TimeInterval = 0
    /// What the last move to the Bin came to, shown until the next scan.
    @Published private(set) var note: String?
    /// By URL rather than by index, because the list reorders when the
    /// filter changes and an index would then point at a different file
    /// than the one somebody ticked.
    @Published var selected: Set<URL> = []
    @Published var showing: LargeFiles.Category? {
        didSet { if showing != oldValue { pruneSelectionToScreen() } }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    lazy var roots = LargeFiles.defaultRoots(home: home)

    enum Layout: String { case folders, list }

    /// Folders by default: the list repeats one long path on row after row,
    /// and a folder is usually the real decision. Remembered, because the
    /// one who prefers the list prefers it every time.
    @Published var layout = Layout(rawValue: Preferences.shared.string(
        "DiskCleaner_layout", default: Layout.folders.rawValue)) ?? .folders {
        didSet { Preferences.shared.set("DiskCleaner_layout", layout.rawValue) }
    }

    /// The open folders, by URL so they stay open across a filter change.
    @Published var expanded: Set<URL> = []

    private let stop = StopFlag()

    /// The shortest a scan is allowed to look.
    ///
    /// A home folder Roost may not read comes back in about 40ms, and a ring
    /// that appears and vanishes inside one frame reads as a glitch rather
    /// than as a scan that found nothing. This is long enough for one full
    /// sweep to be seen, and it only ever delays an answer that was already
    /// complete.
    private static let shortestScan: TimeInterval = 1.4

    // MARK: Scanning

    func scan() {
        guard phase != .scanning else { return }
        stop.set(false)
        let started = Date()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            phase = .scanning
            progress = LargeFiles.Progress()
            found = []
            selected = []
            showing = nil
            note = nil
        }

        let roots = self.roots
        let stop = self.stop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Forty-five seconds, not the walk's default eight. The eight was
            // for a window that showed "Looking…" and nothing else; this one
            // shows the count climbing and has a Stop button, so a long scan
            // no longer looks hung. And the clock runs while macOS's folder
            // prompt is up -- seen here: somebody reading "Roost would like to
            // access files in your Downloads folder" for eight seconds got an
            // empty list for answering it.
            let items = LargeFiles.scan(roots: roots, limit: 40,
                                        deadline: Date().addingTimeInterval(45),
                                        shouldStop: { stop.isSet }) { report in
                DispatchQueue.main.async { self?.progress = report }
            }
            let wait = max(0, Self.shortestScan - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self?.finish(items, started: started)
            }
        }
    }

    func cancel() { stop.set(true) }

    private func finish(_ items: [LargeFiles.Item], started: Date) {
        guard phase == .scanning else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            elapsed = Date().timeIntervalSince(started)
            found = items
            volume = DiskReadings.primary()
            // The top level open and everything under it closed: Desktop,
            // Documents and Downloads with their totals is the overview, and
            // a fully opened tree is the flat list again with indentation.
            expanded = Set(LargeFiles.tree(items, under: home).folders.map(\.url))
            phase = .done
        }
    }

    // MARK: What is shown and ticked

    var filtered: [LargeFiles.Item] {
        guard let showing else { return found }
        return found.filter { $0.category == showing }
    }

    var tree: LargeFiles.Folder { LargeFiles.tree(filtered, under: home) }

    func toggleExpanded(_ folder: LargeFiles.Folder) {
        if expanded.contains(folder.url) { expanded.remove(folder.url) } else { expanded.insert(folder.url) }
    }

    enum Tick { case none, some, all }

    /// Whether a folder's files are ticked: all, some, or none of them.
    func tick(_ folder: LargeFiles.Folder) -> Tick {
        let urls = folder.allFiles.map(\.url)
        let ticked = urls.filter { selected.contains($0) }.count
        if ticked == 0 { return .none }
        return ticked == urls.count ? .all : .some
    }

    /// A partly ticked folder ticks the rest, the way Finder and every
    /// installer's tree treat a mixed box: the click that finishes the job
    /// is the likelier one than the click that undoes it.
    func toggle(_ folder: LargeFiles.Folder) {
        let urls = Set(folder.allFiles.map(\.url))
        if tick(folder) == .all { selected.subtract(urls) } else { selected.formUnion(urls) }
    }

    var breakdown: [(category: LargeFiles.Category, bytes: Int64)] {
        LargeFiles.breakdown(found)
    }

    var totalBytes: Int64 { found.reduce(0) { $0 + $1.bytes } }

    /// Only what is both ticked and on screen, so a filter can never hide a
    /// file the button is about to move.
    var chosen: [LargeFiles.Item] {
        filtered.filter { selected.contains($0.url) }
    }

    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }

    func toggle(_ item: LargeFiles.Item) {
        if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
    }

    var allShownSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selected.contains($0.url) }
    }

    func toggleAllShown() {
        let urls = Set(filtered.map(\.url))
        if allShownSelected { selected.subtract(urls) } else { selected.formUnion(urls) }
    }

    /// A tick on a file the filter has just hidden is a tick somebody can no
    /// longer see, so it goes rather than waiting to surprise them.
    private func pruneSelectionToScreen() {
        selected.formIntersection(Set(filtered.map(\.url)))
    }

    // MARK: Acting

    /// Asks, moves to the Bin, says what happened, then hands back the result.
    ///
    /// Shared rather than private so every cleaner in Roost asks the same
    /// question in the same words, with the size in it, and reaches the
    /// disk through the one `trashItem` line in `LargeFiles.moveToBin`. A
    /// second confirm-and-delete path is a second place for "put in the Bin"
    /// to quietly become "removed".
    ///
    /// `done` runs only if somebody confirmed, on the main thread.
    static func confirmMoveToBin(_ items: [LargeFiles.Item],
                                 done: @escaping (LargeFiles.Removal) -> Void) {
        guard !items.isEmpty else { return }
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        // One file is named, not counted: "1 items" is wrong, and a singular
        // form would only fix the languages that have exactly two.
        let question = items.count == 1
            ? localized("Move %0 to the Bin?", items[0].name)
            : localized("Move %0 items to the Bin?", String(items.count))
        Alert.show(question,
                   localized("%0 will be freed once the Bin is emptied. Until then everything can be put back from Finder.",
                             Readings.bytes(UInt64(bytes))),
                   style: .warning,
                   actionTitle: localized("Move to Bin")) {
            let removal = LargeFiles.moveToBin(items)
            Notify.show(LargeFiles.message(for: removal), symbol: "trash")
            done(removal)
        }
    }

    func moveChosenToBin() {
        Self.confirmMoveToBin(chosen) { [weak self] removal in
            guard let self else { return }
            // Drop what actually moved and leave what did not, so a second
            // press retries only the failures.
            let moved = Set(removal.moved)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                self.found.removeAll { moved.contains($0.url) }
                self.selected.subtract(moved)
                self.note = LargeFiles.message(for: removal)
                if self.filtered.isEmpty { self.showing = nil }
            }
        }
    }

    func reveal(_ item: LargeFiles.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

/// A flag the scanning thread polls and the main thread sets.
private final class StopFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ on: Bool) { lock.lock(); value = on; lock.unlock() }
}

// MARK: - Colours

// The look, for another tab of this page to match: CleanerTint for every
// colour, ScanRing for a ring, GlowButton for the one action on a screen,
// CleanerLink for a quiet secondary one, FilterChip for a filter, CheckCircle
// for a tick (with a mixed state), IndentGuides for nesting. Rows are 12.5pt
// medium over 10.5pt secondary, sizes 12pt rounded monospaced digits, with
// 10pt horizontal and 7pt vertical padding on a 10pt continuous rounded
// highlight. Headline figures are .rounded semibold.

/// The cleaner's colours, all drawn from the validated set in `Palette`.
///
/// Seven categories and six measured series: the six go to the categories
/// somebody is most likely to act on, and the last two -- documents and
/// everything else -- get neutral greys so they recede instead of competing.
/// Installers take the calm teal because they are the one category that is
/// genuinely safe to remove.
enum CleanerTint {
    static var calm: Color { Color(nsColor: .roostCalm) }
    static var warning: Color { Color(nsColor: .roostWarning) }
    static var critical: Color { Color(nsColor: .roostCritical) }

    static func of(_ category: LargeFiles.Category) -> Color {
        switch category {
        case .video:     return Color(nsColor: .roostMagenta)
        case .audio:     return Color(nsColor: .roostOlive)
        case .image:     return Color(nsColor: .roostBlue)
        case .archive:   return warning
        case .installer: return calm
        case .document:  return Color(nsColor: .systemGray)
        case .other:     return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// The disk's own colour, from the disk bands the menu bar and the Disk
    /// popup use, so the ring and the figure in the menu bar never disagree
    /// about "full". Not `LoadBand`, which this first used: that is the
    /// processor's ramp, red from 80%, and it drew an 85% disk red beside a
    /// menu bar figure that was -- correctly, for a disk -- still teal.
    static func ofUsage(_ fraction: Double) -> Color {
        Color(nsColor: MenuBarReading.Severity.ofDisk(fraction).tint)
    }
}

// MARK: - Root view

struct CleanerView: View {
    @ObservedObject var model: CleanerModel
    /// In the settings window, which already draws the glass and has its own
    /// title bar to clear.
    var embedded: Bool

    var body: some View {
        ZStack {
            switch model.phase {
            case .idle:
                CleanerHero(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .scanning:
                CleanerScanning(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            case .done:
                CleanerResults(model: model)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, embedded ? 38 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 460)
        .background {
            if !embedded { CleanerBackdrop().ignoresSafeArea() }
        }
    }
}

struct CleanerBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Start

private struct CleanerHero: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            usageRing
            Spacer().frame(height: 26)

            Text(localized("Find what is taking the room"))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(localized(
                "Roost looks through Downloads, Documents, Desktop, Movies, Music and Pictures for the largest files. Nothing is deleted: what you choose goes to the Bin, where it can be put back."
            ))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Spacer().frame(height: 24)
            GlowButton(title: localized("Scan"), symbol: "sparkle.magnifyingglass",
                       tint: CleanerTint.calm) { model.scan() }

            HStack(spacing: 18) {
                CleanerLink(title: localized("Storage settings…"), symbol: "gearshape") {
                    DiskCleanup.openStorageSettings()
                }
                CleanerLink(title: localized("Open Bin"), symbol: "trash") {
                    DiskCleanup.openBin()
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
    }

    private var usageRing: some View {
        let fraction = model.volume?.percent ?? 0
        let tint = CleanerTint.ofUsage(fraction)
        return ZStack {
            ScanRing(progress: fraction, tint: tint, lineWidth: 14, scanning: false)
            VStack(spacing: 2) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(localized("used"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                if let volume = model.volume {
                    Text(localized("%0 free of %1",
                                   Readings.bytes(volume.free), Readings.bytes(volume.total)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(width: 190, height: 190)
    }
}

// MARK: - Scanning

private struct CleanerScanning: View {
    @ObservedObject var model: CleanerModel

    private var fraction: Double {
        guard !model.roots.isEmpty else { return 0 }
        return Double(model.progress.root) / Double(model.roots.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            ZStack {
                ScanRing(progress: fraction, tint: CleanerTint.calm, lineWidth: 10, scanning: true)
                VStack(spacing: 3) {
                    Text(model.progress.files.formatted())
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.progress.files)))
                        .animation(.snappy(duration: 0.25), value: model.progress.files)
                    Text(localized("files scanned"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1.1)
                    Text(Readings.bytes(UInt64(max(0, model.progress.bytes))))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(CleanerTint.calm)
                        .contentTransition(.numericText())
                        .padding(.top, 3)
                }
                // Inside the sweep, where the radar's own fade would wash it
                // out -- a soft disc keeps the figures readable at any angle.
                .padding(22)
                .background(Circle().fill(.background.opacity(0.55)).blur(radius: 10))
            }
            .frame(width: 230, height: 230)

            Text(model.progress.folder.isEmpty
                 ? localized("Scanning…")
                 : localized("Scanning %0…", model.progress.folder))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
                .padding(.top, 22)
                .animation(nil, value: model.progress.folder)

            RootGrid(roots: model.roots, current: model.progress.root)
                .padding(.top, 18)
                .frame(maxWidth: 440)

            Button(localized("Stop")) { model.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 20)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
    }
}

/// The folders being walked, each saying whether it is done.
private struct RootGrid: View {
    let roots: [URL]
    let current: Int

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                RootChip(url: root,
                         state: index < current ? .done : index == current ? .now : .waiting)
            }
        }
    }
}

private struct RootChip: View {
    // Not `State`: a nested type of that name hides SwiftUI's, and the
    // Swift on the macOS 26 runner then reads `@State` below as this enum.
    // Xcode 27 resolves it, so it built locally and failed only in CI.
    enum Progress { case waiting, now, done }
    let url: URL
    let state: Progress

    @State private var pulse = false

    /// Finder's name for the folder, in the user's language, which is why
    /// none of the six needs a key of its own.
    private var name: String { FileManager.default.displayName(atPath: url.path) }

    private var symbol: String {
        switch url.lastPathComponent {
        case "Downloads": return "arrow.down.circle"
        case "Documents": return "doc"
        case "Desktop":   return "menubar.dock.rectangle"
        case "Movies":    return "film"
        case "Music":     return "music.note"
        case "Pictures":  return "photo"
        default:          return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CleanerTint.calm)
                        .transition(.scale.combined(with: .opacity))
                case .now:
                    Image(systemName: symbol)
                        .foregroundStyle(CleanerTint.calm)
                        .scaleEffect(pulse ? 1.12 : 0.92)
                case .waiting:
                    Image(systemName: symbol)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 16)

            Text(name)
                .font(.system(size: 12, weight: state == .now ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(state == .now ? CleanerTint.calm.opacity(0.14) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(state == .now ? CleanerTint.calm.opacity(0.5) : .clear, lineWidth: 1)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - The ring

/// A progress ring, and while scanning a radar sweep inside it.
///
/// The sweep is drawn in a Canvas under a TimelineView rather than as a
/// rotating view, because what makes it read as a scan is not the rotation
/// but the trail and the ticks catching the light as the line passes -- and
/// those depend on the angle every frame, which a rotation effect cannot
/// express.
struct ScanRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat
    var scanning: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, progress)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint],
                                    center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(360 * max(0.004, min(1, progress)))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.45), radius: lineWidth * 0.7)
                .animation(.spring(response: 0.8, dampingFraction: 0.9), value: progress)
            if scanning {
                RadarSweep(tint: tint)
                    .padding(lineWidth + 7)
                    .transition(.opacity)
            }
        }
    }
}

private struct RadarSweep: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One turn, in seconds. Measured by eye against a stopwatch: at 1.6 the
    /// line read as frantic, and past 3 it read as stalled.
    private static let period = 2.4
    private static let ticks = 72

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Reduce Motion gets the instrument, still, at a fixed angle:
                // it says "scanning" without anything turning.
                let angle = reduceMotion ? -Double.pi / 4
                    : (t.truncatingRemainder(dividingBy: Self.period) / Self.period) * 2 * .pi - .pi / 2
                draw(in: &context, size: size, angle: angle, time: reduceMotion ? 0 : t)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, angle: Double, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2

        // Guide rings and crosshair: faint, so they read as glass etching.
        for fraction in [0.36, 0.68] {
            let r = radius * fraction
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(tint.opacity(0.12)), lineWidth: 0.75)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        context.stroke(cross, with: .color(tint.opacity(0.07)), lineWidth: 0.75)

        // An expanding ripple, one per turn, so the centre breathes.
        let ripple = (time / Self.period).truncatingRemainder(dividingBy: 1)
        let rr = radius * ripple
        context.stroke(Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr,
                                              width: rr * 2, height: rr * 2)),
                       with: .color(tint.opacity(0.25 * (1 - ripple))), lineWidth: 1.5)

        // The trail: a fan of thin wedges behind the line, fading out over
        // a quarter turn.
        let slices = 40
        let trail = Double.pi / 2
        for i in 0..<slices {
            let end = angle - trail * Double(i) / Double(slices)
            let start = end - trail / Double(slices) - 0.004
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: radius,
                         startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            wedge.closeSubpath()
            let fade = 1 - Double(i) / Double(slices)
            context.fill(wedge, with: .color(tint.opacity(0.28 * fade * fade)))
        }

        // Ticks round the edge, lit as the line passes and dimming after.
        for i in 0..<Self.ticks {
            let a = Double(i) / Double(Self.ticks) * 2 * .pi - .pi / 2
            var behind = (angle - a).truncatingRemainder(dividingBy: 2 * .pi)
            if behind < 0 { behind += 2 * .pi }
            let glow = max(0, 1 - behind / (Double.pi * 0.9))
            let long = i % 6 == 0
            let inner = radius - (long ? 8 : 4.5)
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            tick.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
            context.stroke(tick, with: .color(tint.opacity(0.14 + 0.75 * glow)),
                           lineWidth: long ? 1.5 : 1)
        }

        // Blips: fixed points that flare as the line crosses them. Fixed, not
        // random per frame -- points that jump about look like noise, points
        // that stay put look like things found.
        for i in 0..<9 {
            let seed = Double(i) * 2.399963   // the golden angle, so they spread evenly
            let a = seed.truncatingRemainder(dividingBy: 2 * .pi)
            let r = radius * (0.25 + 0.6 * ((Double(i) * 0.618).truncatingRemainder(dividingBy: 1)))
            var behind = (angle - a).truncatingRemainder(dividingBy: 2 * .pi)
            if behind < 0 { behind += 2 * .pi }
            let flare = max(0, 1 - behind / (Double.pi * 1.2))
            guard flare > 0 else { continue }
            let dot = 2 + 2.5 * flare
            let point = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            context.fill(Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot,
                                                width: dot * 2, height: dot * 2)),
                         with: .color(tint.opacity(0.9 * flare)))
        }

        // The line itself, glowing.
        let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        var line = Path()
        line.move(to: center)
        line.addLine(to: tip)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [tint.opacity(0), tint]), startPoint: center, endPoint: tip)
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.stroke(line, with: shading, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)),
                     with: .color(tint))
    }
}

// MARK: - Results

private struct CleanerResults: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            if model.found.isEmpty {
                nothingFound
            } else {
                CategoryStrip(model: model)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                Divider().opacity(0.6)
                list
                Divider().opacity(0.6)
                footer
            }
        }
    }

    private var header: some View {
        let fraction = model.volume?.percent ?? 0
        return HStack(spacing: 14) {
            ZStack {
                ScanRing(progress: fraction, tint: CleanerTint.ofUsage(fraction),
                         lineWidth: 6, scanning: false)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.found.count == 1 && model.found[0].name.count < 40
                     ? localized("%0, %1", model.found[0].name, Readings.bytes(UInt64(model.totalBytes)))
                     : localized("%0 items, %1 in total",
                                 String(model.found.count), Readings.bytes(UInt64(model.totalBytes))))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(model.note ?? localized("%0 files scanned in %1 s",
                                             model.progress.files.formatted(),
                                             String(format: "%.1f", model.elapsed)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.note == nil ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(CleanerTint.calm))
            }
            Spacer(minLength: 8)
            if !model.found.isEmpty {
                Picker(selection: $model.layout) {
                    Image(systemName: "folder").tag(CleanerModel.Layout.folders)
                        .help(localized("Folders"))
                    Image(systemName: "list.bullet").tag(CleanerModel.Layout.list)
                        .help(localized("List"))
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                model.scan()
            } label: {
                Label(localized("Rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var nothingFound: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            // Nothing found usually means permission, not an empty disk --
            // the folders this looks in are the ones macOS guards.
            Text(localized("Nothing found. macOS may not have let Roost look — the folders it searches are the ones it guards."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var list: some View {
        switch model.layout {
        case .folders: folderList
        case .list:    flatList
        }
    }

    private var folderList: some View {
        let tree = model.tree
        let lines = LargeFiles.lines(tree, expanded: model.expanded)
        // Against everything found, not the largest row: a folder and a file
        // inside it are then on one scale, so a folder's bar is visibly the
        // sum of the bars under it.
        let whole = Double(max(1, tree.bytes))
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(lines, id: \.id) { line in
                    switch line {
                    case .folder(let folder, let depth):
                        FolderRow(folder: folder, depth: depth,
                                  share: Double(folder.bytes) / whole,
                                  isOpen: model.expanded.contains(folder.url),
                                  tick: model.tick(folder),
                                  open: { model.toggleExpanded(folder) },
                                  toggle: { model.toggle(folder) },
                                  reveal: { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) })
                    case .file(let item, let depth):
                        FileRow(item: item,
                                share: Double(item.bytes) / whole,
                                isOn: model.selected.contains(item.url),
                                depth: depth,
                                showsFolder: false,
                                toggle: { model.toggle(item) },
                                reveal: { model.reveal(item) })
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var flatList: some View {
        let largest = model.filtered.first?.bytes ?? 1
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.filtered, id: \.url) { item in
                    FileRow(item: item,
                            share: Double(item.bytes) / Double(max(1, largest)),
                            isOn: model.selected.contains(item.url),
                            toggle: { model.toggle(item) },
                            reveal: { model.reveal(item) })
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.combined(with: .move(edge: .trailing))))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.toggleAllShown() }
            } label: {
                Text(model.allShownSelected ? localized("Select none") : localized("Select all"))
            }
            .buttonStyle(.borderless)

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

/// The proportions of what was found, and the filter over it.
private struct CategoryStrip: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        let parts = model.breakdown
        let total = Double(max(1, model.totalBytes))
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.category) { part in
                        Capsule()
                            .fill(CleanerTint.of(part.category).gradient)
                            .frame(width: max(4, (geometry.size.width - CGFloat(parts.count - 1) * 2)
                                               * CGFloat(Double(part.bytes) / total)))
                            .opacity(model.showing == nil || model.showing == part.category ? 1 : 0.25)
                    }
                }
            }
            .frame(height: 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.totalBytes)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: localized("Everything"), bytes: model.totalBytes,
                               tint: .secondary, isOn: model.showing == nil) {
                        model.showing = nil
                    }
                    ForEach(parts, id: \.category) { part in
                        FilterChip(title: part.category.title, bytes: part.bytes,
                                   tint: CleanerTint.of(part.category),
                                   isOn: model.showing == part.category) {
                            model.showing = model.showing == part.category ? nil : part.category
                        }
                    }
                }
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let bytes: Int64
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text(Readings.bytes(UInt64(bytes)))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(isOn ? tint.opacity(0.18)
                                            : Color.primary.opacity(hovering ? 0.08 : 0.045)))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FileRow: View {
    let item: LargeFiles.Item
    /// Its size against the largest on screen, for the bar.
    let share: Double
    let isOn: Bool
    var depth = 0
    /// Off in the tree, where the folder is the row above.
    var showsFolder = true
    let toggle: () -> Void
    let reveal: () -> Void

    @State private var hovering = false

    private var tint: Color { CleanerTint.of(item.category) }

    private var folder: String {
        (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 10) {
            if !showsFolder {
                IndentGuides(depth: depth)
                // Where a folder row has its chevron, so names line up.
                Color.clear.frame(width: 14)
            }
            CheckCircle(tick: isOn ? .all : .none, tint: CleanerTint.critical)

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: showsFolder ? 28 : 22, height: showsFolder ? 28 : 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsFolder {
                    Text(folder)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(item.url.path)

            Spacer(minLength: 8)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.gradient).frame(width: 64 * CGFloat(max(0.04, share)))
            }
            .frame(width: 64, height: 5)

            Text(Readings.bytes(UInt64(item.bytes)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)

            Button(action: reveal) {
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
        .padding(.vertical, showsFolder ? 7 : 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? CleanerTint.critical.opacity(0.10)
                           : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { toggle() } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(localized("Reveal"), action: reveal)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct CheckCircle: View {
    let tick: CleanerModel.Tick
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tick == .none ? Color.secondary.opacity(0.5) : tint, lineWidth: 1.5)
            if tick != .none {
                // A mixed folder is a tinted ring with a bar, not a full disc:
                // at a glance "some of this" must not read as "all of this".
                Circle().fill(tint.opacity(tick == .all ? 1 : 0.25))
                Image(systemName: tick == .all ? "checkmark" : "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(tick == .all ? Color.white : tint)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        // Drawn, so VoiceOver had nothing to read: every tick box in all
        // three cleanup windows was an unnamed button. Named here once, with
        // its state as the value -- "partly" matters, a folder half ticked is
        // a different thing to move to the Bin than a whole one.
        .accessibilityElement()
        .accessibilityLabel(localized("Select"))
        .accessibilityValue(tick == .all ? localized("Selected")
                            : tick == .some ? localized("Partly selected")
                            : localized("Not selected"))
    }
}

/// The vertical lines down the left of a tree, one per level.
struct IndentGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
                    .frame(width: 18)
            }
        }
        // Taller than the row by its padding, so the guides run unbroken
        // from one row into the next instead of reading as dashes.
        .padding(.vertical, -7)
    }
}

/// A folder in the tree: open it, tick everything in it, or reveal it.
private struct FolderRow: View {
    let folder: LargeFiles.Folder
    let depth: Int
    let share: Double
    let isOpen: Bool
    let tick: CleanerModel.Tick
    let open: () -> Void
    let toggle: () -> Void
    let reveal: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            IndentGuides(depth: depth)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 14)

            // A button of its own: the row's click opens the folder, and a
            // tick box that also opened it would make every selection a
            // change of layout too.
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { toggle() }
            } label: {
                CheckCircle(tick: tick, tint: CleanerTint.critical)
            }
            .buttonStyle(.plain)

            // Finder's own icon, so Downloads and Documents carry the glyphs
            // people already know them by.
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                // The file's own name when there is only one, rather than
                // "1 items" -- see moveChosenToBin for why not a singular key.
                Text(folder.count == 1 ? (folder.allFiles.first?.name ?? "")
                                       : localized("%0 items", String(folder.count)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .help((folder.url.path as NSString).abbreviatingWithTildeInPath)

            Spacer(minLength: 8)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [CleanerTint.calm.opacity(0.7), CleanerTint.calm],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 64 * CGFloat(max(0.04, share)))
            }
            .frame(width: 64, height: 5)

            Text(Readings.bytes(UInt64(folder.bytes)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)

            Button(action: reveal) {
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open() }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(localized("Reveal"), action: reveal)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
