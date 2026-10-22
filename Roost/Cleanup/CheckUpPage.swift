import AppKit
import SwiftUI

/// The Check-up: every finder at once, the advice it adds up to, and one
/// list to act on.
///
/// The window draws what `CheckUp` hands it and acts only through
/// `CheckUp.moveToBin`, which checks each file again before it goes. Its
/// own decisions are about reading order:
///
/// - **Advice first, then the list.** A list of 40 rows says nothing about
///   whether any of it matters; three sentences do, and each one says what
///   it would gain and what it could cost before the row it points at.
/// - **What was moved, not what was freed.** The result reports bytes moved
///   to the Bin, measured as they went, and says in the same breath that the
///   space comes back when the Bin is emptied. Calling it "reclaimed" would
///   be a figure the disk does not agree with.
/// - **One scan per quarter hour.** Coming back to the page shows the last
///   report until it is stale or something has been moved since; "Scan
///   again" is always there.
/// - **Nothing scans until asked.** It is a page in the settings window, and
///   a click in the sidebar is somebody looking around, not asking for every
///   folder they own to be read.
/// A flag a background walk polls to know it should stop. Its own type
/// rather than the Disk Cleaner's, which is private to that window.
final class ScanStop {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
}

// MARK: - Model

final class CheckUpModel: ObservableObject {

    enum Phase: Equatable { case idle, scanning(CheckUp.Stage), done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: CheckUp.Report?
    @Published var selected: Set<URL> = []
    @Published private(set) var outcome: CheckUp.Outcome?
    @Published private(set) var moving = false

    /// Shared by every window, so closing and reopening shows the same report.
    private static var lastReport: CheckUp.Report?
    private static var lastContext = CheckUp.Context()
    /// When anything Roost moved to the Bin last moved -- here or in any
    /// window that reports it -- which makes an older report stale.
    static var lastMove: Date?

    private var context = CheckUp.Context()
    /// A new flag for every scan. One shared flag was reset by Start before
    /// a stopped scan had looked at it, so both scans finished, and the
    /// older one could land last and re-tick rows somebody had unticked.
    private var stop = ScanStop()

    var entries: [CheckUp.Entry] { report?.entries ?? [] }
    var chosen: [CheckUp.Entry] { entries.filter { selected.contains($0.url) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var recommendations: [Recommendations.Recommendation] { report?.recommendations ?? [] }

    /// On showing the page: the last report if it is still good, otherwise
    /// the start screen.
    func appear() {
        guard phase == .idle, CheckUp.isFresh(Self.lastReport, lastMove: Self.lastMove),
              let report = Self.lastReport else { return }
        context = Self.lastContext
        show(report)
    }

    func scan() {
        if case .scanning = phase { return }
        let stop = ScanStop()
        self.stop = stop
        outcome = nil
        phase = .scanning(.leftovers)

        var context = CheckUp.Context()
        context.lookup = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        context.assistantDays = AICleanupModel.storedDays
        // Read here, on the main thread, where NSWorkspace keeps it current.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CheckUp.run(
                context: context, running: running,
                appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                shouldStop: { stop.isSet },
                stage: { stage in DispatchQueue.main.async { [weak self] in
                    if case .scanning = self?.phase { self?.phase = .scanning(stage) }
                } })
            DispatchQueue.main.async { [weak self] in
                guard let self, !stop.isSet, stop === self.stop else { return }
                self.context = result.context
                Self.lastReport = result.report
                Self.lastContext = result.context
                self.show(result.report)
            }
        }
    }

    func cancel() {
        stop.set(true)
        if case .scanning = phase { phase = .idle }
    }

    private func show(_ report: CheckUp.Report) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            self.report = report
            self.selected = Set(report.entries.filter(\.isTickedByDefault).map(\.url))
            self.phase = .done
        }
    }

    // MARK: Choosing

    func toggle(_ entry: CheckUp.Entry) {
        if selected.contains(entry.url) { selected.remove(entry.url) } else { selected.insert(entry.url) }
    }

    func tick(_ section: CheckUp.Section) -> CleanerModel.Tick {
        let rows = entries.filter { $0.section == section }
        let ticked = rows.filter { selected.contains($0.url) }.count
        if ticked == 0 { return .none }
        return ticked == rows.count ? .all : .some
    }

    func toggle(_ section: CheckUp.Section) {
        let urls = Set(entries.filter { $0.section == section }.map(\.url))
        if tick(section) == .all { selected.subtract(urls) } else { selected.formUnion(urls) }
    }

    // MARK: Acting

    func moveChosenToBin() {
        let items = chosen
        guard !items.isEmpty, !moving else { return }
        let reviewCount = items.filter { !$0.isTickedByDefault }.count
        var detail = localized("%0 items, %1, go to the Bin. Anything that changed since the scan is left where it is.",
                               String(items.count), Readings.size(UInt64(chosenBytes)))
            + "\n\n" + localized("The space comes back when the Bin is emptied.")
        if reviewCount > 0 {
            // Said here because these are the rows a default would not have
            // chosen: settings and app data are not re-created.
            detail += "\n\n" + localized("%0 of them you ticked yourself. Settings and app data are not re-created.",
                                         String(reviewCount))
        }
        Alert.show(localized("Move %0 to the Bin?", Readings.size(UInt64(chosenBytes))), detail,
                   style: .warning, actionTitle: localized("Move to Bin")) { [weak self] in
            self?.perform(items)
        }
    }

    private func perform(_ items: [CheckUp.Entry]) {
        moving = true
        var context = self.context
        // What is installed and running *now*, not at the scan: an app
        // installed since, and never opened, is one LaunchServices may not
        // know yet, and its data stops being a leftover the moment it lands.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            context.known = OrphanedData.knownIdentifiers(home: context.home, running: running)
            context.mounted = StaleDownloads.mountedImages()
            let outcome = CheckUp.moveToBin(items, in: context, trash: CheckUp.trashItem,
                                            log: { Log.info($0) })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Self.lastMove = Date()
                let gone = Set(outcome.moved.map(\.url))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    self.moving = false
                    self.outcome = outcome
                    self.report?.entries.removeAll { gone.contains($0.url) }
                    self.selected.subtract(gone)
                }
            }
        }
    }

    func follow(_ recommendation: Recommendations.Recommendation, scrollToList: () -> Void) {
        switch recommendation.destination {
        case .checkUpList:      scrollToList()
        case .duplicates:       ToolPages.openDuplicates(reusing: report?.duplicates)
        case .backgroundItems:  ToolPages.open(.backgroundItems)
        case .storageSettings:  DiskCleanup.openStorageSettings()
        case .activityMonitor:  Self.openActivityMonitor()
        case .protection(let check): Self.open(check)
        }
    }

    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// The page with a protection's switch. SIP has none: it is changed only
    /// from Recovery, so the honest answer is the steps.
    static func open(_ check: Protection.Check) {
        switch check {
        case .sip:
            // Led by whether to bother: SIP off is nearly always somebody's
            // own choice, and the steps are only for the case it was not.
            Alert.show(localized("System Integrity Protection is changed from Recovery"),
                       localized("If you did not turn it off yourself, turn it back on:")
                       + "\n\n" + localized("Shut down, then start up holding the power button (Apple silicon) or ⌘R (Intel).")
                       + "\n" + localized("Choose Options, then open Terminal from the Utilities menu and type:")
                       + "\n\n    csrutil enable\n\n" + localized("Then restart."))
        case .gatekeeper:      SettingsLink.privacySecurity.open()
        case .fileVault:       SettingsLink.fileVault.open()
        case .firewall:        SettingsLink.firewall.open()
        case .securityUpdates: SettingsLink.softwareUpdate.open()
        }
    }
}

// MARK: - Views

/// The Check-up before it has run: what it is, the six things it looks at,
/// and the button.
///
/// It was `ToolHero` -- an icon, a sentence and a button centred in the
/// whole pane -- which suits a tool that does one thing. The Check-up does
/// six, and the sentence listing them was the only place they were named,
/// so the page was a small block in a large empty pane that said least about
/// the one tool that most needs explaining. The six are laid out here as the
/// scan runs them, in `CheckUp.Stage` order, each with the tile of the page
/// that does the same job on its own.
private struct CheckUpStart: View {
    let start: () -> Void

    private struct Area: Identifiable {
        let id: CheckUp.Stage
        let glyph: Glyph
        let name: String
        let detail: String
    }

    private var areas: [Area] {
        CheckUp.Stage.allCases.map { stage in
            switch stage {
            case .leftovers:
                return Area(id: stage, glyph: .named("Uninstaller"),
                            name: localized("Leftovers of removed apps"),
                            detail: localized("Folders in your Library for apps that are gone."))
            case .downloads:
                return Area(id: stage, glyph: Glyph(symbol: "arrow.down.circle.fill", color: .blue),
                            name: localized("Finished downloads"),
                            detail: localized("Installers already run, and downloads that never finished."))
            case .assistants:
                return Area(id: stage, glyph: .named("AI tools"),
                            name: localized("AI tools"),
                            detail: localized("Caches, logs and old updates. Sign-ins stay."))
            case .duplicates:
                return Area(id: stage, glyph: .named("Duplicates"),
                            name: localized("Duplicates"),
                            detail: localized("Files stored more than once, compared byte for byte."))
            case .protection:
                return Area(id: stage, glyph: .named("macOS protections"),
                            name: localized("macOS protections"),
                            detail: localized("FileVault, the firewall, Gatekeeper and the rest."))
            case .background:
                return Area(id: stage, glyph: .named("Background items"),
                            name: localized("Background items"),
                            detail: localized("What starts on its own and keeps running."))
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    GlyphTile(glyph: .named("Check-up"), size: 56)
                    Text(localized("Check-up"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(localized("One scan across six places where space and settings pile up. You see what it found before anything moves."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Adaptive: two columns while each cell gets 260pt -- enough
                // for the longest line on two rows -- and one below that, so
                // a narrow window gets a list rather than six squeezed cells.
                // `ViewThatFits` was tried first and always chose one column:
                // a lazy grid's ideal width is not the width it can fill.
                grid

                VStack(spacing: 8) {
                    GlowButton(title: localized("Start check-up"), symbol: "play.fill",
                               tint: .green, action: start)
                        .keyboardShortcut(.defaultAction)
                    Text(localized("Nothing is moved or changed while Roost looks."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            // Wide enough for two columns of a name and a line each, and no
            // wider: past this the eye loses the row between tile and words.
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var grid: some View {
        let layout = [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)]
        return LazyVGrid(columns: layout, spacing: 10) {
            ForEach(areas) { area in
                HStack(alignment: .top, spacing: 10) {
                    GlyphTile(glyph: area.glyph, size: 26, flat: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.name)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(area.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct CheckUpView: View {
    @ObservedObject var model: CheckUpModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .idle:
                CheckUpStart { model.scan() }
                    .transition(.opacity)
            case .scanning:
                scanning.transition(.opacity)
            case .done:
                results.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, ToolPages.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.appear() }
    }

    private var stage: CheckUp.Stage? {
        if case .scanning(let stage) = model.phase { return stage }
        return nil
    }

    private var scanning: some View {
        let fraction = Double((stage?.rawValue ?? 0)) / Double(CheckUp.Stage.allCases.count)
        return VStack(spacing: 16) {
            ScanRing(progress: fraction, tint: CleanerTint.calm, lineWidth: 10, scanning: true)
                .frame(width: 160, height: 160)
            Text(stage?.title ?? localized("Looking…"))
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: stage)
            Text(localized("Nothing is moved or changed while Roost looks."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button(localized("Stop")) { model.cancel() }.keyboardShortcut(.cancelAction)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let outcome = model.outcome { OutcomeBanner(outcome: outcome) }
                        advice(reader)
                        review.id("review")
                        if let report = model.report {
                            DuplicatesCard(scan: report.duplicates)
                            ProtectionCard(report: report.protection)
                            BackgroundCard(report: report)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                }
            }
            Divider().opacity(0.6)
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Check-up"))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                if let report = model.report {
                    Text(Self.when(report.finished))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(localized("Scan again")) { model.scan() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    /// "Scanned just now" under a minute: the relative formatter says "in 0
    /// seconds" for a date a moment ago, which reads as the future.
    private static func when(_ date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return localized("Scanned just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return localized("Scanned %0", formatter.localizedString(for: date, relativeTo: Date()))
    }

    @ViewBuilder
    private func advice(_ reader: ScrollViewProxy) -> some View {
        let list = model.recommendations
        CheckUpHeading(text: localized("What is worth doing"))
        if list.isEmpty {
            Label(localized("Nothing needs doing. Roost checked space, memory, heat, protections, background items, duplicates and leftovers."),
                  systemImage: "checkmark.seal")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(list, id: \.id) { rec in
                AdviceCard(rec: rec) {
                    model.follow(rec) { withAnimation { reader.scrollTo("review", anchor: .top) } }
                }
            }
        }
    }

    @ViewBuilder
    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            CheckUpHeading(text: localized("What can go"))
            if model.entries.isEmpty {
                Text(localized("Nothing left by removed apps, no finished downloads and no AI caches to clear."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            ForEach(CheckUp.Section.allCases, id: \.self) { section in
                let rows = model.entries.filter { $0.section == section }
                if !rows.isEmpty {
                    ReviewSection(section: section, rows: rows, model: model)
                }
            }
            if let held = model.report?.heldBack, held > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    Text(localized("%0 of AI conversations and models are not listed here.", Readings.size(UInt64(held))))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Review in AI tools…")) { ToolPages.open(.aiTools) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !model.chosen.isEmpty {
                Text(localized("%0 selected · %1", String(model.chosen.count),
                               Readings.size(UInt64(model.chosenBytes))))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if model.moving { ProgressView().controlSize(.small) }
            GlowButton(title: model.chosen.isEmpty
                       ? localized("Move to Bin")
                       : localized("Move %0 to Bin", Readings.size(UInt64(model.chosenBytes))),
                       symbol: "trash", tint: CleanerTint.critical, compact: true,
                       enabled: !model.chosen.isEmpty && !model.moving) {
                model.moveChosenToBin()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

struct CheckUpHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One recommendation: the problem and its evidence, then -- on request --
/// what it would gain and what it could cost, and the button that acts.
private struct AdviceCard: View {
    let rec: Recommendations.Recommendation
    let act: () -> Void
    @State private var open = false

    private var tint: Color {
        switch rec.severity {
        case .warning:    return CleanerTint.critical
        case .suggestion: return CleanerTint.warning
        case .note:       return Color(nsColor: .roostBlue)
        }
    }

    private var symbol: String {
        switch rec.severity {
        case .warning:    return "exclamationmark.triangle.fill"
        case .suggestion: return "lightbulb.fill"
        case .note:       return "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.problem).font(.system(size: 13, weight: .semibold))
                    Text(rec.evidence)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(rec.action, action: act).controlSize(.small)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    detail(localized("What it gains"), rec.benefit)
                    detail(localized("What it could cost"), rec.risk)
                    detail(localized("How sure"), rec.confidence == .measured
                           ? localized("Measured: macOS reported this directly.")
                           : localized("A rule applied to what was found. Usually right, so check before acting."))
                    if rec.needsConfirmation {
                        detail(localized("Before anything changes"),
                               localized("You see the list and confirm. Nothing happens from this button alone."))
                    }
                }
                .padding(.leading, 30)
                .transition(.opacity)
            }
            Button(open ? localized("Less") : localized("Why, and what it could cost")) {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.leading, 30)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private func detail(_ title: String, _ text: String) -> some View {
        (Text(title + ": ").font(.system(size: 11, weight: .semibold))
            + Text(text).font(.system(size: 11)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReviewSection: View {
    let section: CheckUp.Section
    let rows: [CheckUp.Entry]
    @ObservedObject var model: CheckUpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button { model.toggle(section) } label: {
                    CheckCircle(tick: model.tick(section), tint: CleanerTint.critical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("Select all in %0", section.title))
                Image(systemName: section.symbol).foregroundStyle(CleanerTint.calm)
                    .accessibilityHidden(true)
                Text(section.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Readings.size(UInt64(rows.reduce(0) { $0 + $1.bytes })))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .padding(.trailing, 34)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Text(section.explanation)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(rows, id: \.url) { entry in
                EntryRow(entry: entry, isOn: model.selected.contains(entry.url)) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { model.toggle(entry) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

private struct EntryRow: View {
    let entry: CheckUp.Entry
    let isOn: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var tint: Color { entry.isTickedByDefault ? CleanerTint.critical : CleanerTint.warning }

    /// A Launch Services lookup, and the list redraws on every tick.
    private static let icons = NSCache<NSString, NSImage>()

    /// Finder's own icon: a .dmg looks like a disk image and a settings file
    /// like one, which says what a row is before its name is read.
    private var icon: NSImage {
        let key = entry.url.path as NSString
        if let hit = Self.icons.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: entry.url.path)
        Self.icons.setObject(image, forKey: key)
        return image
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    CheckCircle(tick: isOn ? .all : .none, tint: tint)
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: 22, height: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 0) {
                            Text(entry.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            if let detail = entry.detail {
                                Text(" · " + detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    .truncationMode(.middle)
                            }
                            if !entry.isTickedByDefault {
                                Text(" · ").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                Text(localized("check before removing"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(CleanerTint.warning)
                            }
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    SizeText(bytes: entry.bytes, isMeasured: entry.isMeasured)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.url.path)
            .accessibilityValue(isOn ? localized("Selected") : localized("Not selected"))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .tertiary)
            .help(localized("Reveal in Finder"))
            .accessibilityLabel(localized("Reveal in Finder"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? tint.opacity(0.10) : Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}

/// What the last move did, in words that do not overstate it.
private struct OutcomeBanner: View {
    let outcome: CheckUp.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !outcome.moved.isEmpty {
                Label(localized("%0 items, %1, moved to the Bin.",
                                String(outcome.moved.count), Readings.size(UInt64(outcome.bytesMoved)))
                      + " " + localized("The space comes back when the Bin is emptied."),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(CleanerTint.calm)
            }
            if !outcome.refused.isEmpty {
                Label(localized("%0 left where they were: they changed after the scan.", String(outcome.refused.count)),
                      systemImage: "hand.raised.fill")
                    .foregroundStyle(CleanerTint.warning)
                    .help(outcome.refused.map(\.path).joined(separator: "\n"))
            }
            ForEach(outcome.failed, id: \.url) { failure in
                Label(localized("%0 could not be moved: %1", failure.url.lastPathComponent, failure.reason),
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(CleanerTint.critical)
            }
            if !outcome.moved.isEmpty {
                Button(localized("Open Bin")) { DiskCleanup.openBin() }.controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct DuplicatesCard: View {
    let scan: Duplicates.Scan?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CheckUpHeading(text: localized("Duplicates"))
            HStack {
                if let scan, !scan.groups.isEmpty {
                    Text(localized("%0 sets of identical files, %1 in spare copies",
                                   String(scan.groups.count),
                                   Readings.size(UInt64(scan.groups.reduce(0) { $0 + $1.reclaimable }))))
                } else if scan != nil {
                    Text(localized("No identical files over 1 MB in Desktop, Documents, Downloads, Movies, Music or Pictures."))
                }
                Spacer()
                Button(localized("Review duplicates…")) { ToolPages.openDuplicates(reusing: scan) }
                    .controlSize(.small)
            }
            .font(.system(size: 12.5))
            if let scan, !scan.isComplete {
                Text(localized("The comparison stopped at its time limit. The Duplicates window looks for longer."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProtectionCard: View {
    let report: Protection.Report?
    /// Off on the page of the same name, whose title already says it.
    var showsHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeading { CheckUpHeading(text: localized("macOS protections")) }
            if let report {
                ForEach(Protection.Check.allCases, id: \.self) { check in
                    ProtectionRow(check: check, state: report.states[check] ?? .unknown)
                }
                if let xprotect = report.xprotect {
                    Text(Self.xprotectLine(xprotect))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(localized("XProtect version %0", xprotect.version))
                }
                Text(localized("Roost reports what macOS says about itself. It is not a malware scanner; XProtect, built into macOS, is."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// When, not which: a version number like 5328 means nothing to read,
    /// and how long ago the definitions changed is the part that says
    /// whether they are current. The version is still on hover.
    private static func xprotectLine(_ info: Protection.XProtectInfo) -> String {
        guard let updated = info.updated else {
            return localized("Malware definitions: version %0", info.version)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return localized("Malware definitions updated %0", formatter.localizedString(for: updated, relativeTo: Date()))
    }
}

struct ProtectionRow: View {
    let check: Protection.Check
    let state: Protection.State

    private var text: String {
        switch state {
        case .on:        return localized("On")
        // The firewall is off on a new Mac, and the page says so in its
        // description; showing that in amber beside a button read as a
        // problem Roost had found.
        case .off where check == .firewall: return localized("Off (macOS default)")
        case .off:       return localized("Off")
        case .defaultOn: return localized("On (macOS default)")
        case .unknown:   return localized("Could not be read")
        }
    }

    private var tint: Color {
        switch state {
        case .on, .defaultOn: return CleanerTint.calm
        case .off where check == .firewall: return .secondary
        case .off:            return check.isEssential ? CleanerTint.critical : CleanerTint.warning
        case .unknown:        return .secondary
        }
    }

    private var buttonTitle: String {
        if check == .sip { return localized("How to turn it on…") }
        if state == .unknown { return localized("Check in System Settings…") }
        return check == .firewall ? localized("Turn on…") : localized("Settings…")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title).font(.system(size: 12.5, weight: .medium))
                Text(check.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            // Unknown gets a way forward too: macOS not answering is not a
            // reason to leave somebody with a grey dot and nothing to click.
            if state == .off || state == .unknown {
                Button(buttonTitle) { CheckUpModel.open(check) }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BackgroundCard: View {
    let report: CheckUp.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CheckUpHeading(text: localized("What runs in the background"))
            HStack {
                Text(summary).font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(localized("Review background items…")) { ToolPages.open(.backgroundItems) }
                    .controlSize(.small)
            }
        }
    }

    /// Counts as "label: n" rather than "n launch jobs": the language has
    /// no plural forms to hand here, and "1 launch jobs" read as careless.
    /// A count of zero is left out instead of reported.
    private var summary: String {
        let missing = report.jobsMissingProgram
        let unsigned = report.jobsUnsigned
        let total = localized("Background items: %0", String(report.jobs.count))
        if missing == 0 && unsigned == 0 {
            return total + " · " + localized("all signed and still installed")
        }
        var parts = [total]
        if missing > 0 { parts.append(localized("left by a removed app: %0", String(missing))) }
        if unsigned > 0 { parts.append(localized("from an unidentified developer: %0", String(unsigned))) }
        return parts.joined(separator: " · ")
    }
}
