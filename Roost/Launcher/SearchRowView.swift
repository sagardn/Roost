import AppKit

/// A button that acts on the very first click.
///
/// AppKit spends the first click in an inactive window on activating it, so
/// the arrow did nothing when the panel was opened by the trackpad gesture --
/// the app is not frontmost then. Same reason the results table needed it.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One search result: icon, running dot, name, a ⌃⇥ badge if the app is in
/// the switcher, and an arrow on the right that opens that app's options.
///
/// The arrow is only drawn for the row the keyboard is on, or the one the
/// pointer is over -- an arrow on all eight rows at once reads as clutter and
/// competes with the running dots. The space it occupies is reserved either
/// way, so names do not shift as the selection moves.
final class SearchRowView: NSView {

    let arrow = FirstMouseButton()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isCurrent = false {
        didSet { if isCurrent != oldValue { updateArrow() } }
    }

    private var hovering = false {
        didSet { if hovering != oldValue { updateArrow() } }
    }

    init(name: String, icon: NSImage?, mark: String, font: NSFont, arrowWidth: CGFloat,
         marked: Bool = false) {
        super.init(frame: .zero)

        let image = NSImageView(image: icon ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: name)
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSTextField(labelWithString: mark)
        dot.font = .systemFont(ofSize: 10)
        dot.textColor = .secondaryLabelColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        // The glyph is the only thing on screen saying whether an app is
        // open, and VoiceOver read it as "black circle". The words it stands
        // for go on the name instead, and in a tooltip for the pointer.
        let state = Self.state(of: mark)
        dot.toolTip = state
        dot.setAccessibilityElement(false)

        // Marking an app is what makes ⌃Tab cycle it, and until now the only
        // place that was visible was the options menu -- so the list gave no
        // way to see what the switcher would actually walk through.
        let badge = NSTextField(labelWithString: "\u{2303}\u{21E5}")
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = !marked
        badge.toolTip = localized("In the ⌃Tab switcher")
        badge.setAccessibilityElement(false)
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel(([name, state] + [marked ? localized("In the ⌃Tab switcher") : nil])
            .compactMap { $0 }.joined(separator: ", "))

        arrow.isBordered = false
        arrow.bezelStyle = .regularSquare
        arrow.imagePosition = .imageOnly
        arrow.image = NSImage(systemSymbolName: "chevron.right",
                              accessibilityDescription: localized("App options (→)"))
        arrow.imageScaling = .scaleNone
        arrow.toolTip = localized("App options (→)")
        arrow.alphaValue = 0
        arrow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(image)
        addSubview(dot)
        addSubview(label)
        addSubview(badge)
        addSubview(arrow)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 26),
            image.heightAnchor.constraint(equalToConstant: 26),

            dot.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),

            badge.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 16),

            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: arrowWidth),
            arrow.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the running mark means: `SearchPanel` draws ● for an app with
    /// windows open and ○ for one whose windows are all minimised.
    private static func state(of mark: String) -> String? {
        switch mark {
        case "●": return localized("Running")
        case "○": return localized("Minimised")
        default:  return nil
        }
    }

    private func updateArrow() {
        arrow.alphaValue = (isCurrent || hovering) ? 1 : 0
        arrow.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
    }

    // MARK: - Hover

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
