import AppKit

/// Sizes shared by the popup window and everything laid out inside it.
enum PopupMetrics {
    static let windowWidth: CGFloat = 340
    static let inset: CGFloat = 14
    /// Was 9, room for the overlay scroller, which drew on top of the
    /// right-aligned values. The popups no longer show a scroller, so the
    /// content takes the full width and the margins are even again.
    static let scrollerGutter: CGFloat = 0
    static var contentWidth: CGFloat { windowWidth - inset * 2 - scrollerGutter }
}

// MARK: - Section header

/// A small caps title with a hairline running out to each side.
final class SectionHeader: NSView {

    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let left = rule(), right = rule()
        addSubview(left)
        addSubview(label)
        addSubview(right)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 14),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),

            right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func rule() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}

// MARK: - Label / value row

/// Label on the left, value on the right. The value is settable so a refresh
/// updates the text in place rather than rebuilding the row.
final class ValueRow: NSView {

    /// A plain-words explanation on hover, for a row whose label is the
    /// standard term but not a common one. Returns the row, so it can be
    /// written where the row is declared.
    func explained(_ text: String) -> ValueRow {
        toolTip = text
        return self
    }

    private let valueField = NSTextField(labelWithString: "—")
    private var nameField: NSTextField?
    private var pill: StatusPill?

    var value: String {
        get { valueField.stringValue }
        set { valueField.stringValue = newValue }
    }

    /// Settable for the rows whose label is itself a reading -- one per
    /// accelerator, where the name of the device is what the row is about.
    var label: String {
        get { nameField?.stringValue ?? "" }
        set { nameField?.stringValue = newValue }
    }

    /// `symbol` puts a tinted SF Symbol before the label, the way the two
    /// transfer totals are marked with their arrows.
    init(_ label: String, symbol: String? = nil, tint: NSColor? = nil, pill: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: label)
        nameField = name
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        valueField.font = .systemFont(ofSize: 11, weight: .medium)
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingHead
        valueField.translatesAutoresizingMaskIntoConstraints = false

        let leading = NSStackView()
        leading.spacing = 4
        leading.translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            glyph.contentTintColor = tint ?? .secondaryLabelColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.widthAnchor.constraint(equalToConstant: 11).isActive = true
            leading.addArrangedSubview(glyph)
        }
        leading.addArrangedSubview(name)

        addSubview(leading)

        let trailing: NSView
        if pill {
            let badge = StatusPill()
            self.pill = badge
            trailing = badge
        } else {
            trailing = valueField
        }
        addSubview(trailing)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),

            leading.leadingAnchor.constraint(equalTo: leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor,
                                              constant: 8)
        ])
        // The value wins the squeeze: a truncated label still reads, a
        // truncated figure does not.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(_ up: Bool, upText: String = "UP", downText: String = "DOWN") {
        pill?.set(up ? upText : downText, good: up)
    }
}

// MARK: - Status pill

/// The filled capsule the screenshot uses for UP / DOWN.
final class StatusPill: NSView {

    private let label = NSTextField(labelWithString: "—")
    private var good = true

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.alignment = .center
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ text: String, good: Bool) {
        label.stringValue = text
        self.good = good
        needsDisplay = true
        updateLayer()
    }

    /// Resolved here rather than stored as a CGColor at init, which would
    /// keep the light-mode shade after a switch to dark.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (good ? NSColor.systemGreen : NSColor.systemRed)
            .withAlphaComponent(0.85).cgColor
    }
}

// MARK: - Big reading

/// The headline pair at the top of the popup: a large figure, its unit, and a
/// captioned arrow underneath.
final class BigReading: NSView {

    private let figure = NSTextField(labelWithString: "0")
    private let unit = NSTextField(labelWithString: "")

    init(caption: String, symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        figure.font = .systemFont(ofSize: 26, weight: .regular)
        figure.translatesAutoresizingMaskIntoConstraints = false
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor
        unit.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView(views: [figure, unit])
        top.alignment = .firstBaseline
        top.spacing = 4

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.contentTintColor = tint
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let bottom = NSStackView(views: [glyph, label])
        bottom.spacing = 3

        let column = NSStackView(views: [top, bottom])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Already-formatted figure and unit, for readings that are neither a
    /// percentage nor a byte count.
    func set(text: String, unit suffix: String) {
        figure.stringValue = text
        unit.stringValue = suffix
    }

    /// 0...1 shown as a percentage, with the sign as the small half.
    func set(percent value: Double) {
        figure.stringValue = String(format: "%.0f", min(max(value, 0), 1) * 100)
        unit.stringValue = "%"
    }

    /// A byte count, large number and unit split apart.
    func set(bytes: UInt64) {
        let text = Readings.bytes(bytes)
        let parts = text.split(separator: " ", maxSplits: 1)
        figure.stringValue = parts.first.map(String.init) ?? "0"
        unit.stringValue = parts.count > 1 ? String(parts[1]) : ""
    }

    /// Split so the number is large and the unit is not -- "4" and "KB/s".
    func set(bytesPerSecond: Double) {
        let text = Readings.rate(bytesPerSecond)
        let parts = text.split(separator: " ", maxSplits: 1)
        figure.stringValue = parts.first.map(String.init) ?? "0"
        unit.stringValue = parts.count > 1 ? String(parts[1]) : ""
    }
}

// MARK: - Traffic chart

/// Upload above the centre line, download below, on one shared scale, with
/// each side's peak printed in the corner it belongs to.
///
/// Upload on top because every other view of a link puts it there: the menu
/// bar stacks ↑ over ↓, and its own chart and the tile's draw upload above.
/// This one had them the other way up, so a glance at the popup after the
/// menu bar read a download spike as an upload.
///
/// Self-contained rather than built on Kit's chart views, which
/// pins itself to a fixed size -- here the chart has to stretch to the popup.
final class TrafficChart: NSView {

    var download: [Double] = [] { didSet { needsDisplay = true } }
    var upload: [Double] = [] { didSet { needsDisplay = true } }

    var downloadColor: NSColor = .systemIndigo
    var uploadColor: NSColor = .roostAmber

    /// Floor on the scale, so an idle link does not magnify a few stray bytes
    /// into a mountain range.
    private let minimumCeiling: Double = 64 * 1024

    init(height: CGFloat = 92) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let area = bounds.insetBy(dx: 3, dy: 3)
        let middle = area.midY

        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: area.minX, y: middle, width: area.width, height: 1)).fill()

        let peak = max(download.max() ?? 0, upload.max() ?? 0, minimumCeiling)
        series(upload, uploadColor, up: true, in: area, middle: middle, peak: peak)
        series(download, downloadColor, up: false, in: area, middle: middle, peak: peak)

        // Named as peaks, with the series' arrow in its colour. A bare figure
        // at an edge reads as what the edge stands for, and the edges share
        // one scale: the smaller side's peak sat at a top edge that was
        // really the larger side's.
        if let top = upload.max(), top > 0 {
            label("↑ peak " + Readings.rate(top), uploadColor,
                  at: NSPoint(x: area.minX + 3, y: area.maxY - 13))
        }
        if let bottom = download.max(), bottom > 0 {
            label("↓ peak " + Readings.rate(bottom), downloadColor,
                  at: NSPoint(x: area.minX + 3, y: area.minY + 2))
        }
    }

    private func series(_ values: [Double], _ tint: NSColor, up: Bool,
                        in area: NSRect, middle: CGFloat, peak: Double) {
        guard values.count > 1 else { return }
        let step = area.width / CGFloat(values.count - 1)
        let reach = area.height / 2 - 1

        func point(_ index: Int) -> NSPoint {
            let fraction = min(max(values[index] / peak, 0), 1)
            let offset = CGFloat(fraction) * reach
            return NSPoint(x: area.minX + CGFloat(index) * step,
                           y: up ? middle + offset : middle - offset)
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: area.minX, y: middle))
        for index in values.indices { fill.line(to: point(index)) }
        fill.line(to: NSPoint(x: area.maxX, y: middle))
        fill.close()
        tint.withAlphaComponent(0.25).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        line.move(to: point(0))
        for index in values.indices.dropFirst() { line.line(to: point(index)) }
        tint.setStroke()
        line.stroke()
    }

    private func label(_ text: String, _ tint: NSColor, at origin: NSPoint) {
        let arrow = String(text.prefix(1))
        let line = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        line.addAttribute(.foregroundColor, value: tint,
                          range: NSRange(location: 0, length: (arrow as NSString).length))
        line.draw(at: origin)
    }
}

// MARK: - Connectivity grid

/// One square per probe, oldest top-left. Green answered, red did not.
final class SquaresGrid: NSView {

    var results: [Bool] = [] { didSet { needsDisplay = true } }

    private let square: CGFloat = 9
    private let gap: CGFloat = 2
    private let rows = 3

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: CGFloat(rows) * square
                                    + CGFloat(rows - 1) * gap)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var columns: Int {
        max(1, Int((bounds.width + gap) / (square + gap)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let capacity = columns * rows
        // Newest last in the array, and the grid fills left to right, top to
        // bottom -- so an over-long history drops from the front.
        let shown = results.suffix(capacity)

        for (index, ok) in shown.enumerated() {
            let column = index % columns
            let row = index / columns
            let rect = NSRect(x: CGFloat(column) * (square + gap),
                              y: bounds.maxY - CGFloat(row + 1) * square - CGFloat(row) * gap,
                              width: square, height: square)
            (ok ? NSColor.systemGreen : NSColor.systemRed)
                .withAlphaComponent(ok ? 0.8 : 0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - Process row

/// Icon, name, and the two rate columns under their colour chips.
/// A window that must stay open while one of its own menus is up.
///
/// A popup closes when it stops being the key window, and opening a menu is
/// exactly that. `ReadingPopup` already carried the flag for its header's
/// gear menu; this is the part of it a row needs, named separately so a row
/// does not have to know about the window class -- which lives behind the
/// macOS 26 glass APIs and would drag all of them into every test that
/// compiles a row.
protocol MenuHostingWindow: AnyObject {
    var isShowingOwnMenu: Bool { get set }
}

final class ProcessRow: NSView {

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let down = NSTextField(labelWithString: "")
    private let up = NSTextField(labelWithString: "")
    /// The way to the quit menu that does not depend on knowing to
    /// right-click. Right-click was the only way, and nothing on the row
    /// said so: asked to "add a kill option", the person asking had used
    /// these popups daily without finding it. Shown on hover only, so a
    /// list of twelve rows is not a column of twelve buttons.
    private let stop = NSButton()
    private var hovering = false { didSet { syncHover() } }

    /// Who this row is currently about. Rows are built once and reused as the
    /// list resorts, so this is set on every update and read only inside the
    /// menu it opens -- never cached by the menu, or a right-click would act
    /// on whoever occupied the row two samples ago.
    private var pid: Int32 = 0

    static let columnWidth: CGFloat = 62

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        for field in [down, up] {
            field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        addSubview(icon)
        addSubview(name)

        stop.image = NSImage(systemSymbolName: "xmark.circle.fill",
                             accessibilityDescription: localized("Quit or force quit"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        stop.isBordered = false
        stop.imagePosition = .imageOnly
        stop.contentTintColor = .secondaryLabelColor
        stop.target = self
        stop.action = #selector(showStopMenu)
        stop.toolTip = localized("Quit or force quit")
        stop.translatesAutoresizingMaskIntoConstraints = false
        stop.isHidden = true
        addSubview(stop)

        wantsLayer = true
        layer?.cornerRadius = 4

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 18),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -4),

            // Beside the figures, not over them: the number is what the row
            // is for, and hiding it under the pointer would hide it from the
            // very person deciding whether to quit.
            stop.trailingAnchor.constraint(equalTo: down.leadingAnchor, constant: -2),
            stop.centerYAnchor.constraint(equalTo: centerYAnchor),
            stop.widthAnchor.constraint(equalToConstant: 16),
            stop.heightAnchor.constraint(equalToConstant: 16),

            down.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -6),
            down.centerYAnchor.constraint(equalTo: centerYAnchor),
            down.widthAnchor.constraint(equalToConstant: Self.columnWidth),

            up.trailingAnchor.constraint(equalTo: trailingAnchor),
            up.centerYAnchor.constraint(equalTo: centerYAnchor),
            up.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// One value instead of two columns -- the CPU table's shape.
    func set(name: String, pid: Int32, value: String) {
        self.pid = pid
        identify(pid: pid, sampled: name)
        down.stringValue = ""
        up.stringValue = value
    }

    func set(_ entry: ProcessNetwork.Entry) {
        pid = entry.pid
        identify(pid: entry.pid, sampled: entry.name)
        down.stringValue = Readings.rate(entry.download)
        up.stringValue = Readings.rate(entry.upload)
    }

    /// A gear, not Terminal, for a process with no app: most of them are
    /// system services, and none of them is a terminal.
    private func identify(pid: Int32, sampled: String) {
        let identity = ProcessIdentity.identify(pid: pid, fallback: sampled)
        name.stringValue = identity.name
        toolTip = identity.name == sampled ? nil : sampled
        icon.image = identity.icon ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    }

    // MARK: - Force quit

    /// The whole row answers a click, not whichever label is under it.
    ///
    /// Without this the menu works everywhere except on the process name --
    /// which is the part anybody would aim at. A right-click is delivered to
    /// the deepest view it hits, that is the NSTextField, and a label has no
    /// menu of its own and does not pass the question to its superview. The
    /// row's children are an icon and three labels, none of which wants a
    /// click, so the row can take them all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The one child that does want a click.
        if !stop.isHidden, stop.frame.contains(local) { return stop }
        return self
    }

    // MARK: - Hover

    /// `.activeAlways`: the popup is a panel that is often not key, and a
    /// tracking area that only works in the key window would never fire.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    /// A row with no pid -- an empty slot -- shows nothing on hover, as it
    /// offers no menu.
    private func syncHover() {
        let live = hovering && ProcessControl.isSignallable(pid)
        stop.isHidden = !live
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = live ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
        }
    }

    /// Right-click offers to end the process this row is about.
    ///
    /// Built per click rather than kept, so it is always about whoever is in
    /// the row now. A row with no pid -- an empty slot in a list built for
    /// more processes than are running -- offers no menu at all rather than
    /// a menu that does nothing.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = stopMenu() else { return nil }
        // The popup closes when it stops being the key window, and opening a
        // menu is exactly that. The flag is the window's own, already used by
        // the header's gear menu.
        (window as? MenuHostingWindow)?.isShowingOwnMenu = true
        return menu
    }

    /// The same menu, from the hover button, under the button.
    @objc private func showStopMenu() {
        guard let menu = stopMenu() else { return }
        let host = window as? MenuHostingWindow
        host?.isShowingOwnMenu = true
        // Synchronous: it returns once the menu has closed, chosen or not.
        menu.popUp(positioning: nil, at: NSPoint(x: stop.frame.minX, y: stop.frame.minY), in: self)
        host?.isShowingOwnMenu = false
    }

    private func stopMenu() -> NSMenu? {
        guard ProcessControl.isSignallable(pid) else { return nil }

        let process = name.stringValue
        let menu = NSMenu()

        // Quit first, and not only because it is alphabetically unlucky:
        // the top item is the one a fast hand lands on, and of the two this
        // is the one that lets the process save.
        for (title, action) in [(localized("Quit %0", process), #selector(quit)),
                                (localized("Force Quit %0", process), #selector(forceQuit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        (window as? MenuHostingWindow)?.isShowingOwnMenu = true
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        (window as? MenuHostingWindow)?.isShowingOwnMenu = false
    }

    @objc private func quit() {
        // Confirmed even though it is the gentle one: the rows are eighteen
        // points tall and seven of them sit together, so the cost of a slip
        // is somebody else's unsaved work either way.
        confirm(title: localized("Quit %0?", name.stringValue),
                // One literal, not two joined: the i18n scan reads the
                // argument as written, and a key split across a `+` is a key
                // it cannot find.
                detail: localized("The process is asked to quit and may offer to save first."),
                style: .informational,
                actionTitle: localized("Quit"),
                act: ProcessControl.quit)
    }

    @objc private func forceQuit() {
        confirm(title: localized("Force quit %0?", name.stringValue),
                detail: localized("The process ends immediately. Anything it has not saved is lost."),
                style: .warning,
                actionTitle: localized("Force Quit"),
                act: ProcessControl.forceQuit)
    }

    /// Both items ask first, then act on the pid the row held when the menu
    /// opened -- not whatever is in the row by the time the alert is answered,
    /// which may be a different process entirely.
    private func confirm(title: String, detail: String, style: NSAlert.Style,
                         actionTitle: String,
                         act: @escaping (Int32) -> ProcessControl.Outcome) {
        let target = pid
        let process = name.stringValue
        guard ProcessControl.isSignallable(target) else { return }

        Alert.show(title, detail, style: style, actionTitle: actionTitle) {
            let outcome = act(target)
            if let message = ProcessControl.message(for: outcome, name: process) {
                Notify.show(message, symbol: "exclamationmark.triangle")
            }
        }
    }
}

/// The header above the process table: which column is download and which
/// is upload.
///
/// It was two colour chips with no words, which asked a person to match the
/// chips to the headline readings' colours to know which number was which.
/// The words sit over the columns they name, in the same widths, and keep
/// the colours.
final class ProcessHeader: NSView {

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: localized("Process"))
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let down = column("↓ " + localized("Down"), .systemIndigo)
        let up = column("↑ " + localized("Up"), .roostAmber)
        addSubview(down)
        addSubview(up)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            down.trailingAnchor.constraint(equalTo: up.leadingAnchor, constant: -6),
            down.centerYAnchor.constraint(equalTo: centerYAnchor),
            down.widthAnchor.constraint(equalToConstant: ProcessRow.columnWidth),

            up.trailingAnchor.constraint(equalTo: trailingAnchor),
            up.centerYAnchor.constraint(equalTo: centerYAnchor),
            up.widthAnchor.constraint(equalToConstant: ProcessRow.columnWidth)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func column(_ title: String, _ color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = color
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// What a process table says when it has no rows: "Measuring…" until the
/// first sample, then why it is empty. A header over nothing looked broken.
final class ProcessPlaceholder: NSTextField {

    init(_ measuring: String = localized("Measuring…")) {
        super.init(frame: .zero)
        stringValue = measuring
        isEditable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11)
        textColor = .tertiaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown only while `rows` is zero; `empty` is the words for a sample
    /// that came back with nothing in it.
    func show(rows: Int, empty: String) {
        isHidden = rows > 0
        if rows == 0 { stringValue = empty }
    }
}

// MARK: - Core bars

/// One slim bar per logical core, each tinted by its own load.
///
/// A row of bars rather than eight labelled rows: at this size the shape of
/// the load -- four performance cores busy, four efficiency cores idle -- is
/// the thing worth seeing, and the exact figure per core is not.
final class CoreBars: NSView {

    var loads: [Double] = [] { didSet { needsDisplay = true } }
    /// Marks where the efficiency cluster ends, so the two groups read apart.
    var clusterBreak: Int?

    init(height: CGFloat = 34) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard !loads.isEmpty else { return }

        let gap: CGFloat = 3
        let groupGap: CGFloat = clusterBreak == nil ? 0 : 6
        let total = bounds.width - gap * CGFloat(loads.count - 1) - groupGap
        let barWidth = max(2, total / CGFloat(loads.count))

        var x: CGFloat = 0
        for (index, load) in loads.enumerated() {
            if let clusterBreak, index == clusterBreak { x += groupGap }

            let track = NSRect(x: x, y: 0, width: barWidth, height: bounds.height)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

            let filled = max(2, bounds.height * CGFloat(min(max(load, 0), 1)))
            let bar = NSRect(x: x, y: 0, width: barWidth, height: filled)
            LoadBand.of(load).color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

            x += barWidth + gap
        }
    }
}

// MARK: - History chart

/// A single series over time, filled to the baseline.
///
/// The tint follows the latest value through the shared load ramp, so a
/// chart that has climbed into the red says so without needing a legend.
final class HistoryChart: NSView {

    var values: [Double] = [] { didSet { needsDisplay = true } }
    /// Top of the scale. 1 for a percentage; nil scales to the data.
    var ceiling: Double? = 1

    init(height: CGFloat = 70) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PopupMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        guard values.count > 1 else { return }
        let area = bounds.insetBy(dx: 3, dy: 3)
        let top = max(ceiling ?? values.max() ?? 1, 0.0001)
        let step = area.width / CGFloat(values.count - 1)

        func point(_ index: Int) -> NSPoint {
            let fraction = min(max(values[index] / top, 0), 1)
            return NSPoint(x: area.minX + CGFloat(index) * step,
                           y: area.minY + CGFloat(fraction) * area.height)
        }

        let tint = LoadBand.of(values.last ?? 0).color

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: area.minX, y: area.minY))
        for index in values.indices { fill.line(to: point(index)) }
        fill.line(to: NSPoint(x: area.maxX, y: area.minY))
        fill.close()
        tint.withAlphaComponent(0.25).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        line.move(to: point(0))
        for index in values.indices.dropFirst() { line.line(to: point(index)) }
        tint.setStroke()
        line.stroke()
    }
}
