import AppKit

/// The Free up space page: the five ways Roost can help with a full disk.
///
/// It was a section at the bottom of the Disk module's settings, which is
/// where it was written and the wrong place for it. That page configures the
/// Disk *module* -- which volume it watches, which shapes it draws in the
/// menu bar, when it warns. These rows configure nothing; they are actions,
/// and they are about the Mac rather than about a module.
///
/// Each row carries an icon, a title and a line saying what it does, rather
/// than a bare label and a button. The labels alone were not enough: the one
/// that uninstalls an app read "An app or tool you no longer want", which
/// says what it is for but not what it does, and it was looked straight past.
final class CleanupPane: NSStackView {

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        translatesAutoresizingMaskIntoConstraints = false

        // Roost asks for no disk permission of its own. The first two rows
        // hand the job to something that already has one; the rest search
        // only what macOS lets any app read.
        let macOSCan = Controls.section(localized("What macOS can do"), [
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

        let roostCan = Controls.section(localized("What Roost can find"), [
            CleanupRow(symbol: "doc.viewfinder.fill", tint: .systemIndigo,
                       title: localized("Large files"),
                       detail: localized("The biggest files in your home folder, by kind: video, audio, archives, installers."),
                       button: localized("Find large files…"), opens: .review,
                       action: LargeFilesWindow.present),
            CleanupRow(symbol: "sparkles", tint: .systemPink,
                       title: localized("AI assistants"),
                       detail: localized("Conversation history, caches, logs and downloaded updates. The tools stay installed and signed in."),
                       button: localized("Clean up…"), opens: .review,
                       action: AICleanupWindow.present),
            CleanupRow(symbol: "xmark.bin.fill", tint: .systemRed,
                       title: localized("Uninstall an app or tool"),
                       detail: localized("Removes the app and the files it left around the system, or a command-line tool and its settings."),
                       button: localized("Uninstall…"), opens: .review,
                       action: UninstallWindow.present)
        ])

        let note = NSTextField(wrappingLabelWithString:
            localized("Everything Roost removes goes to the Bin, so nothing is erased until you empty it."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [macOSCan, roostCan, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 44, left: 18, bottom: 18, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            macOSCan.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            roostCan.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            note.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Nothing to refresh: the page holds no reading, only five ways in.
    func viewWillAppear() {}
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
    /// three open a window of Roost's own that finds things and asks before
    /// moving any of them. The buttons looked identical, so "Open Bin" and
    /// "Uninstall…" read as the same kind of click. The ones that leave carry
    /// the outward arrow macOS uses for a link out, and every one says in
    /// its tooltip what happens next.
    enum Destination {
        case systemSettings, finder, review

        var help: String {
            switch self {
            case .systemSettings: return localized("Opens System Settings.")
            case .finder:         return localized("Opens the Bin in Finder.")
            case .review:         return localized("Opens a window that shows what it found. Nothing moves until you confirm.")
            }
        }

        var leavesRoost: Bool { self != .review }
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
