import AppKit

/// The Storage page: the disk, how full it is, and the two jobs macOS does
/// better than Roost.
///
/// It was the Free up space hub -- the disk and then a button per tool, each
/// opening a window of its own -- and before that a section at the bottom of
/// the Disk module's settings. The tools are pages in the sidebar now, under
/// Cleanup, Files and Applications, so this keeps what belongs to no one tool:
/// the disk itself, how Roost removes things, and the hand-offs to Storage
/// settings and the Bin. It also points at the Check-up, which is the answer
/// to "where do I start" that a page of figures cannot give.
///
/// Each row carries an icon, a title and a line saying what it does, rather
/// than a bare label and a button. The labels alone were not enough: the one
/// that uninstalled an app read "An app or tool you no longer want", which
/// says what it is for but not what it does, and it was looked straight past.
final class CleanupPane: NSStackView {

    private let storage = StorageSummary()

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        translatesAutoresizingMaskIntoConstraints = false

        orientation = .vertical
        alignment = .leading
        spacing = RoostMetrics.sectionSpacing
        edgeInsets = NSEdgeInsets(top: RoostMetrics.pageTop, left: RoostMetrics.pageInset,
                                  bottom: RoostMetrics.pageInset, right: RoostMetrics.pageInset)

        // The page leads with the disk itself. It was five buttons with
        // nothing to say whether any of them was worth pressing: a Mac with
        // 300 GB free and one with 3 GB got the same page.
        let disk = Controls.section(nil, [Controls.row(storage)])

        let start = Controls.section(nil, [
            CleanupRow(symbol: "stethoscope", tint: .systemGreen,
                       title: localized("Not sure where to start?"),
                       detail: localized("The Check-up runs every tool at once and says which findings are worth acting on."),
                       button: localized("Open Check-up"), opens: .page,
                       action: { ToolPages.open(.checkUp) })
        ])

        // Before the tools, not after them. The sentence saying everything
        // goes to the Bin was a footer under the last card, read -- if at
        // all -- after somebody had already decided not to press anything.
        let how = Controls.section(localized("How Roost cleans up"), [
            Controls.row(StepStrip([
                (localized("Roost looks"),
                 localized("It lists what it found and how big each thing is. Nothing is touched.")),
                (localized("You choose"),
                 localized("Tick what you want gone. Leave the rest.")),
                (localized("It goes to the Bin"),
                 localized("Changed your mind? Put it back from the Bin."))
            ], tint: .controlAccentColor))
        ])

        // Roost asks for no disk permission of its own. These two hand the
        // job to something that already has one.
        let macOS = Controls.section(localized("Let macOS help"), [
            CleanupRow(symbol: "internaldrive.fill", tint: .systemOrange,
                       title: localized("Space macOS can reclaim"),
                       detail: localized("Backups and caches the system can hand back on its own."),
                       button: localized("Storage settings…"), opens: .systemSettings,
                       action: DiskCleanup.openStorageSettings),
            CleanupRow(symbol: "trash.fill", tint: .systemGray,
                       title: localized("Deleted files"),
                       detail: localized("Nothing is really gone until the Bin is emptied."),
                       button: localized("Open Bin"), opens: .finder,
                       action: DiskCleanup.openBin)
        ])

        for section in [disk, start, how, macOS] {
            addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: widthAnchor,
                                           constant: -RoostMetrics.pageInset * 2).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The disk is read each time the page is shown, so it answers for
    /// whatever the tools have just moved to the Bin.
    func viewWillAppear() { storage.refresh() }
}

/// The disk the page is about: how full it is, in a bar and in words.
///
/// The same volume the Large files window reads, so the two never disagree
/// about which disk is meant.
private final class StorageSummary: NSView {

    private let name = NSTextField(labelWithString: "")
    private let amount = NSTextField(labelWithString: "")
    private let bar = StorageBar()
    private let legend = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        amount.font = .systemFont(ofSize: 13)
        amount.textColor = .secondaryLabelColor
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        legend.font = .systemFont(ofSize: 11)
        legend.lineBreakMode = .byTruncatingTail
        legend.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [name, amount, bar, legend] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            amount.trailingAnchor.constraint(equalTo: trailingAnchor),
            amount.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            amount.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            bar.heightAnchor.constraint(equalToConstant: 10),

            legend.leadingAnchor.constraint(equalTo: leadingAnchor),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            legend.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 7),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        guard let volume = DiskReadings.primary(), volume.total > 0 else {
            name.stringValue = localized("Disk")
            amount.stringValue = ""
            legend.attributedStringValue = NSAttributedString()
            bar.parts = (0, 0)
            return
        }
        let size = Readings.size
        name.stringValue = volume.name
        amount.stringValue = localized("%0 available of %1", size(volume.free), size(volume.total))

        // Coloured by the same bands the Disk module warns at, so the bar
        // goes amber here exactly when the menu bar does.
        let used = Self.colour(SeverityBands.disk.zone(volume.percent))
        let total = Double(volume.total)
        bar.usedColour = used
        bar.parts = (Double(volume.used) / total, Double(volume.purgeable) / total)

        // A dot of each colour and a word for it: the bar's segments are
        // not something to decode by colour alone.
        let text = NSMutableAttributedString()
        func add(_ colour: NSColor, _ words: String) {
            if text.length > 0 {
                text.append(NSAttributedString(string: "    "))
            }
            text.append(NSAttributedString(string: "\u{25CF} ", attributes: [
                .foregroundColor: colour, .font: NSFont.systemFont(ofSize: 10)]))
            text.append(NSAttributedString(string: words, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        }
        add(used, localized("%0 used", size(volume.used)))
        if volume.purgeable > 0 {
            add(used.withAlphaComponent(StorageBar.purgeableAlpha),
                localized("%0 macOS can reclaim", size(volume.purgeable)))
        }
        add(.quaternaryLabelColor, localized("%0 free now", size(volume.freeNow)))
        legend.attributedStringValue = text
    }

    private static func colour(_ zone: Int) -> NSColor {
        switch zone {
        case 2:  return .roostCritical
        case 1:  return .roostWarning
        default: return .controlAccentColor
        }
    }
}

/// Used, then what macOS can reclaim, then free, as one rounded bar.
private final class StorageBar: NSView {

    /// The reclaimable segment is the used colour, faded: it is used space
    /// until macOS needs it, and free space after.
    static let purgeableAlpha: CGFloat = 0.4

    var parts: (used: Double, purgeable: Double) = (0, 0) { didSet { needsDisplay = true } }
    var usedColour: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let used = bounds.width * CGFloat(min(max(parts.used, 0), 1))
        let purgeable = bounds.width * CGFloat(min(max(parts.purgeable, 0), 1))
        usedColour.setFill()
        NSRect(x: 0, y: 0, width: used, height: bounds.height).fill()
        usedColour.withAlphaComponent(Self.purgeableAlpha).setFill()
        NSRect(x: used, y: 0, width: purgeable, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// An icon, a title, a line of explanation, and the button that does it.
///
/// The icon is drawn the way the sidebar draws its own: a rounded tinted
/// tile with a white glyph, so a row here and a row there read as the same
/// kind of thing.
private final class CleanupRow: NSView {

    /// Where a button takes you, said before it is pressed.
    ///
    /// Two of these leave Roost for an app that does the job better, and
    /// the other stays in this window. The buttons looked identical, so
    /// "Open Bin" and a tool of Roost's own read as the same kind of click.
    /// The ones that leave carry the outward arrow macOS uses for a link out,
    /// and every one says in its tooltip what happens next.
    enum Destination {
        case systemSettings, finder, page

        var help: String {
            switch self {
            case .systemSettings: return localized("Opens System Settings.")
            case .finder:         return localized("Opens the Bin in Finder.")
            case .page:           return localized("Opens its page in this window.")
            }
        }

        var leavesRoost: Bool { self != .page }
    }

    private let pressed: () -> Void

    init(symbol: String, tint: NSColor, title: String, detail: String,
         button: String, opens destination: Destination, action: @escaping () -> Void) {
        self.pressed = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let tile = TintedTile(symbol: symbol, tint: tint)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        name.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [name, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        let control = NSButton(title: button, target: self, action: #selector(press))
        control.bezelStyle = .rounded
        control.toolTip = destination.help
        if destination.leavesRoost {
            control.image = NSImage(systemSymbolName: "arrow.up.forward",
                                    accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            control.imagePosition = .imageTrailing
        } else {
            // Roost's own tools in the accent colour, the hand-offs plain:
            // the arrow alone was too small to tell the two kinds apart at
            // a glance down the column of buttons.
            control.bezelColor = .controlAccentColor
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [tile, text, control] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),

            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor,
                                           constant: -12),

            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func press() { pressed() }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The sidebar's icon tile, in a settings row.
private final class TintedTile: NSView {

    init(symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = tint.cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let image = NSImageView()
        // A symbol macOS does not have draws nothing at all, and an empty
        // coloured square is worse than no icon.
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        image.contentTintColor = .white
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
