import SwiftUI
import AppKit

/// The Dashboard: how the Mac is doing now, and what it is.
///
/// It replaced a page of hardware facts led by a 160pt picture of the
/// machine, which put the first useful line below the fold of a 480pt window
/// and said nothing that changes from one minute to the next except uptime.
/// The order now is the order of the questions: is anything wrong, what are
/// the readings, and -- folded away until asked for -- what is this Mac.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    /// The one thing on this page that samples: see DashboardProcesses.

    @StateObject private var processes = DashboardProcesses()
    @State private var customizing = false

    var body: some View {
        // The width comes from the scroll view's visible area, never from the
        // content. It used to be measured off the cards themselves, which is
        // a loop: anything that made the page a little wide made the cards
        // wider, which made the page wider, and a 1100pt window rendered
        // with every edge cut off. The visible area cannot be widened by
        // what is inside it.
        GeometryReader { viewport in
        let width = max(0, viewport.size.width - RoostMetrics.pageInset * 2)
        ScrollView {
            VStack(alignment: .leading, spacing: RoostMetrics.sectionSpacing) {
                header
                status
                cards(width: width)
                if model.layout.visible.contains(.disk) {
                    StoragePanel(state: model.states[.disk] ?? .waiting, uptime: model.uptime, width: width,
                                 open: { model.open(DashboardCard.disk.module) },
                                 enable: { model.enable(DashboardCard.disk.module) })
                }
                BusiestProcesses(processes: processes)
                DeviceDetails(model: model)
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, RoostMetrics.pageInset)
            // Not `pageTop`: that is for the AppKit pages, which ignore the
            // title bar and have to clear it themselves. A SwiftUI scroll
            // view is already inset below it, and adding the 44 on top left
            // a band of nothing above the title.
            .padding(.top, RoostMetrics.contentTop)
            .padding(.bottom, RoostMetrics.pageInset)
        }
        }
        // Tied to the model's own liveness rather than to `onAppear`: the
        // settings window keeps a page's view alive after swapping it out,
        // and a table that went on sampling behind another page would be
        // exactly the cost this page is careful not to have.
        .onAppear { processes.isActive = model.isActive }
        .onDisappear { processes.isActive = false }
        .onReceive(model.$isActive) { processes.isActive = $0 }
    }

    // MARK: - Header

    private var header: some View {
        // Side by side where there is room, stacked where there is not, so a
        // narrow window wraps the actions under the title rather than
        // squeezing the title down to "Overv…".
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                actions
            }
        }
    }

    /// "Overview", then which Mac and which macOS, on one line under it.
    ///
    /// The page carries its own title, so the window's toolbar does not
    /// repeat it -- see `SettingsShellView`. The device picture is the
    /// system's own icon at the height of the two lines beside it; the 160pt
    /// one this page used to open with pushed every reading below the fold.
    private var identity: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = DeviceInfo.model.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("Overview"))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(DeviceInfo.model.name) · \(DeviceInfo.os.description)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var summary: String {
        if model.watching == 0, model.states.values.contains(where: Self.isPending) {
            return localized("Waiting for the first readings")
        }
        // On, but with nothing in the menu bar, a module is not sampled and
        // reports nothing -- which the summary below took for "no modules
        // are on", above cards that each said they were.
        if model.watching == 0, model.states.values.contains(where: Self.isUnsampled) {
            return localized("Nothing that is on is in the menu bar, so nothing is being measured")
        }
        return model.summary
    }

    private static func isUnsampled(_ state: DashboardModel.CardState) -> Bool {
        if case .notSampled = state { return true }
        return false
    }

    private var summaryTone: StatusTone {
        model.watching == 0 ? .neutral : StatusTone(model.level)
    }

    private static func isPending(_ state: DashboardModel.CardState) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.open("Free up space")
            } label: {
                Label(localized("Free up space"), systemImage: "sparkles")
            }
            .help(localized("Find large files and apps you no longer use"))

            Button {
                customizing.toggle()
            } label: {
                Label(localized("Customize"), systemImage: "slider.horizontal.3")
            }
            .help(localized("Choose which cards the Dashboard shows, and their order"))
            .popover(isPresented: $customizing, arrowEdge: .bottom) {
                DashboardCustomizer(model: model)
            }
        }
        .controlSize(.regular)
        .fixedSize()
    }

    // MARK: - Status

    /// The verdict, and what it rests on.
    ///
    /// Always there, and one line on a healthy Mac: the verdict and the
    /// readings it was drawn from, so "Everything looks normal" can be read
    /// as the claim it is -- about memory pressure, not how full memory is;
    /// about the link being up, not about the internet answering. An issue
    /// adds a row with what it means and the page that explains it, and
    /// nothing else on the page is ever the place a warning appears.
    private var status: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The verdict and its basis on one line where they fit, the basis
            // under it where they do not -- truncated, it read "From CPU
            // load, memory pressure, free spac…" at the window's narrowest.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    verdict
                    Spacer(minLength: 8)
                    basisText.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    verdict
                    basisText.padding(.leading, 24)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(model.issues) { issue in
                Divider().padding(.vertical, 8)
                // One issue is already named by the verdict above -- see
                // `Health.summary`, which returns the single issue's title
                // verbatim. The row then printed it a second time, two lines
                // apart: "Memory pressure is raised" over "Memory pressure
                // is raised". With one issue the row carries the detail
                // instead, which is the half the verdict cannot say.
                IssueRow(issue: issue, open: model.open,
                         showsTitle: model.issues.count > 1)
            }
        }
        // Full width whichever way the line wrapped, so the box's edge lines
        // up with the cards' under it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var verdict: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: summaryTone.symbol)
                .foregroundStyle(summaryTone.color)
                .accessibilityHidden(true)
            Text(summary)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var basisText: some View {
        Text(basis)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(localized("Drawn from the modules that are on. A module that is off is not checked."))
    }

    /// Which readings the verdict rests on, named as what they measure.
    private var basis: String {
        let names = model.basis.map(\.basisName)
        guard !names.isEmpty else { return localized("No readings yet") }
        return localized("From %0", ListFormatter.localizedString(byJoining: names))
    }

    // MARK: - Cards

    private func cards(width gridWidth: CGFloat) -> some View {
        Group {
            if model.layout.visible.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Every card is hidden"))
                        .font(.headline)
                    Text(localized("Customize the Dashboard to bring back the readings you want here."))
                        .foregroundStyle(.secondary)
                    Button(localized("Show the standard cards")) { model.restoreDefaultLayout() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface()
            } else {
                // Columns chosen, not adaptive -- see `DashboardGrid`.
                // Storage is not a card: it is the panel under them. Battery
                // is a card only on a Mac that has one; a desktop leaves no
                // empty space for it.
                let visible = model.layout.visible.filter {
                    $0 != .disk && ($0 != .battery || model.charge != nil)
                }
                let count = DashboardGrid.columns(for: visible.count, width: gridWidth,
                                                  spacing: RoostMetrics.gridSpacing)
                // Rows of equal cards, and a short last row whose cards share
                // its width: three cards in a window wide enough for two
                // left Network alone in half a row, with the other half empty.
                //
                // Each card is given its width outright, as a grid column
                // would give it. Left to the row to share out, the cards
                // asked for their content's natural width, and three of
                // those came to 20pt more than a 1400pt window has.
                VStack(alignment: .leading, spacing: RoostMetrics.gridSpacing) {
                    ForEach(Array(stride(from: 0, to: visible.count, by: count)), id: \.self) { start in
                        let row = visible[start..<min(start + count, visible.count)]
                        let gaps = RoostMetrics.gridSpacing * CGFloat(row.count - 1)
                        let width = max(0, (gridWidth - gaps) / CGFloat(row.count))
                        HStack(alignment: .top, spacing: RoostMetrics.gridSpacing) {
                            ForEach(row) { card in
                                Group {
                                    if card == .battery {
                                        BatteryCard(model: model)
                                    } else {
                                        MetricCard(card: card, state: model.states[card] ?? .waiting,
                                                   open: { model.open(card.module) },
                                                   enable: { model.enable(card.module) })
                                    }
                                }
                                .frame(width: width)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Issue

private struct IssueRow: View {
    let issue: HealthIssue
    let open: (String) -> Void
    /// False when the verdict above has already said it: the title, and the
    /// tone symbol that goes with it, would both be the second copy.
    var showsTitle = true

    var body: some View {
        let tone = StatusTone(issue.level)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: showsTitle ? tone.symbol : "arrow.turn.down.right")
                .foregroundStyle(showsTitle ? tone.color : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if showsTitle {
                    Text(issue.title)
                        .font(.body.weight(.semibold))
                }
                Text(issue.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            // VoiceOver reads the verdict and this row as separate elements,
            // so the one that drops its title has to carry the issue's name
            // itself or the detail is read with nothing to attach it to.
            .accessibilityLabel(showsTitle ? issue.explanation
                                           : "\(issue.title). \(issue.explanation)")
            Spacer(minLength: 8)
            if issue.module == "Disk" {
                Button(localized("Free up space")) { open("Free up space") }
                    .controlSize(.small)
            }
            Button(localized("Details")) { open(issue.module) }
                .controlSize(.small)
                .help(localized("Open the %0 page", localized(issue.module)))
        }
    }
}

// MARK: - Card

/// One module's reading.
///
/// The whole card is the button that opens the module's page, so it is one
/// stop for the keyboard and one element for VoiceOver -- named for the
/// module, valued with every figure on it. A card with no reading is not a
/// button: it carries the one control that would give it a reading instead.
/// Internal rather than private: the Storage panel shows this card in its
/// place while the Disk module is off, starting or not being measured.
struct MetricCard: View {
    let card: DashboardCard
    let state: DashboardModel.CardState
    let open: () -> Void
    let enable: () -> Void

    /// Fixed, so a card waiting for its first sample is the size it will be
    /// with one, and the grid does not reflow under the pointer.
    static let height: CGFloat = 176

    var body: some View {
        switch state {
        case .reading(let report) where report.unavailable == nil:
            Button(action: open) { reading(report) }
                .buttonStyle(CardButtonStyle())
                .accessibilityLabel(card.title)
                .accessibilityValue(report.spoken)
                .accessibilityHint(localized("Opens the %0 page", card.title))
                .help(localized("Open the %0 page", card.title))
        case .reading(let report):
            placeholder(badge: report.caption, tone: .neutral,
                        message: report.unavailable ?? "", action: nil)
        case .off:
            placeholder(badge: localized("Off"), tone: .neutral,
                        message: localized("Switched off, so it is not being measured."),
                        action: (localized("Turn On"), enable))
        case .notSampled:
            placeholder(badge: localized("Not measured"), tone: .neutral,
                        message: localized("Nothing from this module is in the menu bar, so Roost is not measuring it."),
                        action: (localized("Show in menu bar…"), open))
        case .waiting:
            placeholder(badge: localized("Starting"), tone: .neutral,
                        message: localized("Waiting for the first reading."),
                        action: nil, progress: true)
        case .unsupported:
            placeholder(badge: localized("Unavailable"), tone: .neutral,
                        message: localized("This Mac does not offer this reading."),
                        action: nil)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            GlyphTile(glyph: .named(card.module), size: 18)
            Text(card.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// The figure and its verdict on one line where both fit, the verdict
    /// under the figure where they do not. They shared the title's line
    /// first, and "Pressure: Normal" came out "Pressure: Nor…" in a card of
    /// the grid's narrowest width -- which is the verdict, truncated to the
    /// part that does not say anything.
    private func headline(_ value: String, badge: String, tone: StatusTone) -> some View {
        let figure = Text(value)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                figure.fixedSize()
                Spacer(minLength: 4)
                StatusBadge(text: badge, tone: tone).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                figure.minimumScaleFactor(0.7)
                StatusBadge(text: badge, tone: tone)
            }
        }
    }

    /// Two figures of equal weight: download and upload are both the
    /// reading, and one of them in small print under the other said the
    /// opposite. Smaller than a single headline, so two rates of
    /// "999.9 KB/s" fit the grid's narrowest card side by side.
    private func pairedHeadline(_ pair: (first: (String, String), second: (String, String)),
                                badge: String, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                rate(pair.first.0, pair.first.1)
                rate(pair.second.0, pair.second.1)
            }
            StatusBadge(text: badge, tone: tone)
        }
    }

    private func rate(_ label: String, _ figure: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(figure)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reading(_ report: DashboardReport) -> some View {
        let tone = StatusTone(report.severity)
        return VStack(alignment: .leading, spacing: 6) {
            titleRow
            if let pair = report.pair {
                pairedHeadline(pair, badge: report.caption, tone: tone)
            } else {
                headline(report.value, badge: report.caption, tone: tone)
            }

            Group {
                if report.history.count > 1 {
                    // A calm line in the calm colour, a busy one in the
                    // colour its state is -- the line and the word above it
                    // never disagree.
                    Sparkline(values: report.history, mirror: report.mirror,
                              tint: report.mirror == nil ? tone.color : StatusTone.calm.color)
                } else if let fill = report.fill {
                    VStack { Spacer(minLength: 0); FillGauge(fraction: fill, tone: tone) }
                        .frame(height: 34)
                } else {
                    Color.clear.frame(height: 34)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(report.facts.prefix(3), id: \.self) { fact in
                    HStack(spacing: 6) {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(fact.value)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height - RoostMetrics.cardInset * 2,
               alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func placeholder(badge: String, tone: StatusTone, message: String,
                             action: (String, () -> Void)?, progress: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                titleRow
                StatusBadge(text: badge, tone: tone).fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if progress { ProgressView().controlSize(.small) }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if let action {
                    Button(action.0, action: action.1)
                        .controlSize(.small)
                }
                Spacer()
                Button(localized("Details"), action: open)
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .help(localized("Open the %0 page", card.title))
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height - RoostMetrics.cardInset * 2,
               alignment: .topLeading)
        .surface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }
}

/// A card that is a button: the surface, a hairline of the accent colour
/// under the pointer, and a dip while pressed. No scale and no spring -- the
/// card is a way to a page, not a toy.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .surface()
                .overlay(
                    RoundedRectangle(cornerRadius: RoostMetrics.cardRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(hovering ? 0.55 : 0), lineWidth: 1.5)
                )
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Customizing

/// Which cards, in which order.
///
/// Up and down buttons rather than drag alone: they work from the keyboard
/// and with VoiceOver, which a drag handle does not.
private struct DashboardCustomizer: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: localized("Dashboard cards"),
                         detail: localized("Choose which readings appear, and in what order."))

            VStack(spacing: 0) {
                ForEach(Array(model.layout.order.enumerated()), id: \.element) { index, card in
                    if index > 0 { Divider() }
                    row(card, index: index)
                }
            }
            .surface(padding: 8)

            HStack {
                Button(localized("Restore Defaults")) { model.restoreDefaultLayout() }
                    .disabled(model.layout.isStandard)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ card: DashboardCard, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !model.layout.hidden.contains(card) },
                set: { model.layout = model.layout.setting(card, shown: $0) })) {
                HStack(spacing: 8) {
                    GlyphTile(glyph: .named(card.module), size: 18)
                    Text(card.title)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                model.layout = model.layout.moving(card, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help(localized("Move up"))
            .accessibilityLabel(localized("Move %0 up", card.title))
            Button {
                model.layout = model.layout.moving(card, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == model.layout.order.count - 1)
            .help(localized("Move down"))
            .accessibilityLabel(localized("Move %0 down", card.title))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 5)
    }
}

// MARK: - Device details

/// What this Mac is, folded away by default.
///
/// In two groups, because they answer different questions: what the hardware
/// can do, which does not change, and what it is doing now -- the display's
/// current mode, the system it is running and how long since it started.
private struct DeviceDetails: View {
    @ObservedObject var model: DashboardModel
    @State private var revealSerial = false
    @State private var displays: [DeviceInfo.Display] = []

    var body: some View {
        DisclosureGroup(isExpanded: $model.showsDetails) {
            // One grid, with the two headings as rows spanning it: as two
            // grids, each sized its label column to its own longest label
            // and the values of the second sat 20pt left of the first's.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                heading(localized("Hardware"), first: true)
                rows(hardware)
                heading(localized("Right now"), first: false)
                rows(current)
            }
            .font(.callout)
            .padding(.top, 10)
            .onAppear { displays = DeviceInfo.displays }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DeviceInfo.displays
            }
        } label: {
            Text(localized("About this Mac"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .surface()
    }

    private func heading(_ title: String, first: Bool) -> some View {
        GridRow {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
                .padding(.top, first ? 0 : 8)
                .accessibilityAddTraits(.isHeader)
                .gridCellColumns(2)
        }
    }

    @ViewBuilder
    private func rows(_ rows: [(String, AnyView)]) -> some View {
        ForEach(rows.indices, id: \.self) { index in
            GridRow {
                Text(rows[index].0)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                rows[index].1
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func text(_ value: String) -> AnyView {
        AnyView(Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
    }

    private var hardware: [(String, AnyView)] {
        var rows: [(String, AnyView)] = [(localized("Model"), text(DeviceInfo.model.name))]
        let cpu = DeviceInfo.cpu
        if let name = cpu.name { rows.append((localized("Processor"), text(name))) }
        if let cores = coreLine { rows.append((localized("Cores"), text(cores))) }
        rows.append((localized("Memory"), text(Readings.bytes(UInt64(max(0, DeviceInfo.memory))))))
        if let gpu = DeviceInfo.gpu { rows.append((localized("Graphics"), text(gpu))) }
        let drives = DeviceInfo.drives.map { "\($0.name) · \(Self.medium($0.medium))" }
        if !drives.isEmpty { rows.append((localized("Storage"), text(drives.joined(separator: "\n")))) }
        // In the units the Storage card above uses, which are Finder's: a
        // second formatter here once said 195.38 GB for the 182 GB disk the
        // card described, two honest numbers that read as a contradiction.
        let volumes = DeviceInfo.volumes.map {
            "\($0.name) · \(Readings.size(UInt64(max(0, $0.capacity))))"
        }
        if !volumes.isEmpty { rows.append((localized("Volumes"), text(volumes.joined(separator: "\n")))) }
        for display in displays { rows.append((localized("Display"), text(panel(display)))) }
        // Apple silicon names carry the chip rather than the year, so most
        // Macs have none to show; the row goes rather than saying Unknown.
        if let year = DeviceInfo.model.year {
            rows.append((localized("Production year"), text(String(year))))
        }
        if let serial = DeviceInfo.serialNumber {
            rows.append((localized("Serial number"), AnyView(serialRow(serial))))
        }
        // Last: "Mac15,3" is for a support form, not for reading down the
        // list, where it sat between the display and the year.
        rows.append((localized("Model identifier"), text(DeviceInfo.model.identifier)))
        return rows
    }

    /// IOKit's medium type, in the words people use for drives.
    private static func medium(_ raw: String) -> String {
        switch raw {
        case "Solid State": return localized("SSD")
        case "Rotational":  return localized("Hard disk")
        default:            return raw
        }
    }

    private var current: [(String, AnyView)] {
        let os = DeviceInfo.os
        var rows: [(String, AnyView)] = [
            (localized("System"), text(os.build.isEmpty ? os.description : "\(os.description) (\(os.build))")),
            (localized("Uptime"), text(model.uptime))
        ]
        for display in displays {
            rows.append((displays.count > 1 ? display.name : localized("Display mode"), text(mode(display))))
        }
        return rows
    }

    private var coreLine: String? {
        let cpu = DeviceInfo.cpu
        guard let cores = cpu.physicalCores else { return nil }
        if let performance = cpu.performanceCores, let efficiency = cpu.efficiencyCores {
            return localized("%0 · %1 performance and %2 efficiency", "\(cores)",
                             "\(performance)", "\(efficiency)")
        }
        if let threads = cpu.logicalCores, threads != cores {
            return localized("%0 cores, %1 threads", "\(cores)", "\(threads)")
        }
        return "\(cores)"
    }

    /// The panel: what it is, never what it is set to.
    private func panel(_ display: DeviceInfo.Display) -> String {
        var parts = [display.name]
        if let inches = display.inches { parts.append(String(format: "%.1f″", inches)) }
        if let native = display.native { parts.append("\(native.width) × \(native.height)") }
        if display.maximumHz > 0 { parts.append(localized("up to %0 Hz", "\(display.maximumHz)")) }
        return parts.joined(separator: " · ")
    }

    /// The mode it is in: the size the desktop looks like, the buffer it is
    /// drawn into when that differs, and the refresh rate it is running at.
    private func mode(_ display: DeviceInfo.Display) -> String {
        let looks = display.looksLike
        var parts = [localized("Looks like %0", "\(looks.width) × \(looks.height)")]
        let rendered = display.rendered
        if rendered.width != looks.width {
            parts.append(localized("drawn at %0", "\(rendered.width) × \(rendered.height)"))
        }
        if let hz = display.refreshHz { parts.append("\(hz) Hz") }
        return parts.joined(separator: " · ")
    }

    private func serialRow(_ serial: String) -> some View {
        HStack(spacing: 6) {
            Text(revealSerial ? serial : SerialMask.masked(serial))
                .monospaced()
                .textSelection(.enabled)
                .accessibilityLabel(revealSerial ? serial : localized("Hidden"))
            Button {
                revealSerial.toggle()
            } label: {
                Image(systemName: revealSerial ? "eye.slash" : "eye")
            }
            .help(revealSerial ? localized("Hide the serial number") : localized("Show the serial number"))
            .accessibilityLabel(revealSerial ? localized("Hide the serial number")
                                             : localized("Show the serial number"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serial, forType: .string)
                Notify.show(localized("Serial number copied"), symbol: "doc.on.doc")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(localized("Copy the serial number"))
            .accessibilityLabel(localized("Copy the serial number"))
        }
        .buttonStyle(.borderless)
    }
}
