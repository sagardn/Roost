import AppKit

/// The pieces a settings pane is made of.
///
/// Independent of Kit's `PreferencesSection` / `PreferencesRow` and the
/// `switchView` / `selectView` / `buttonView` helpers on NSView. Same shape on
/// screen — a titled card of rows, label on the left, control on the right —
/// built with constraints rather than computed frames, so a long label wraps
/// or truncates instead of running under its control.
///
/// Rows take a closure instead of a target/selector pair. The old helpers
/// bound every control to an `@objc` method on the pane, which meant a pane
/// could not build a row without also declaring a method for it, and a typo in
/// a selector name was a crash at click time rather than an error at build
/// time.
enum Controls {

    /// A titled group of rows, drawn as one rounded card.
    ///
    /// `symbol` puts a tinted glyph before the title, the same tile the
    /// sidebar uses, so a long page can be scanned by shape before it is
    /// read. `footer` is a sentence under the card saying what the group is
    /// for -- the place for "why would I change this", which a label of two
    /// words cannot carry.
    static func section(_ title: String? = nil,
                        symbol: String? = nil,
                        tint: NSColor = .systemGray,
                        footer: String? = nil,
                        _ rows: [NSView]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 7
        container.translatesAutoresizingMaskIntoConstraints = false

        if let title {
            let heading = NSTextField(labelWithString: title)
            if let symbol {
                heading.font = .systemFont(ofSize: 13, weight: .semibold)
                heading.textColor = .labelColor
                let header = NSStackView(views: [glyph(symbol, tint), heading])
                header.orientation = .horizontal
                header.alignment = .centerY
                header.spacing = 7
                container.addArrangedSubview(header)
            } else {
                heading.font = .systemFont(ofSize: 12, weight: .semibold)
                heading.textColor = .secondaryLabelColor
                container.addArrangedSubview(heading)
            }
        }

        let card = Card()
        card.orientation = .vertical
        card.spacing = 0
        card.edgeInsets = NSEdgeInsets(top: 3, left: RoostMetrics.cardInset,
                                       bottom: 3, right: RoostMetrics.cardInset)
        card.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            if index > 0 { card.addArrangedSubview(separator()) }
            card.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
        }

        container.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        // The card wraps its rows. Without this it is free to take any
        // height above them and hand the difference back to the rows, which
        // is where the blank half of the Keyboard card came from.
        fitToContent(card)

        if let footer {
            let note = NSTextField(wrappingLabelWithString: footer)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(note)
            // Inset to the card's text, so it reads as a caption to the card
            // and not as a row that lost its background.
            note.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24).isActive = true
            container.setCustomSpacing(5, after: card)
            let indent = note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)
            indent.priority = .defaultHigh
            indent.isActive = true
        }
        return container
    }

    /// The sidebar's tile, in AppKit: a white symbol on a rounded square.
    private static func glyph(_ symbol: String, _ tint: NSColor) -> NSView {
        let tile = TintTile(tint)
        tile.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    /// One row: a label and its control.
    ///
    /// The control keeps its natural width and the label takes the rest, so a
    /// pop-up button is never squeezed and a long label is never hidden
    /// underneath one.
    ///
    /// `indented` is for a row that only means something while the row above
    /// it is on -- the combined bar's spacing under "Combine", the finger
    /// counts under the gesture. Set in and quieter, so it reads as part of
    /// that row rather than as one more setting of equal weight.
    ///
    /// `detail` is a line under the label for a setting whose name alone does
    /// not say what it changes. Used sparingly: a caption on every row is a
    /// page nobody reads, and the rows that need one stop standing out.
    static func row(_ label: String, _ control: NSView, indented: Bool = false,
                    detail: String? = nil) -> NSView {
        let view = DetailRow()
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        if indented { title.textColor = .secondaryLabelColor }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text: NSView
        if let detail {
            let caption = NSTextField(wrappingLabelWithString: detail)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [title, caption])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.caption = caption
            view.indent = indented ? 16 : 0
            text = stack
        } else {
            text = title
        }
        text.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.addSubview(text)
        view.addSubview(control)
        view.control = control
        nameControls(in: control, by: title)
        NSLayoutConstraint.activate([
            // 28, not 32: the controls are mini switches and small pop-ups,
            // 22pt at most, and 32 left the settings page a screen and a half
            // of mostly padding.
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: indented ? 16 : 0),
            text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),

            control.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // The row grows to whatever the control needs. Without these a
            // multi-line value -- the processor's cores and threads -- was
            // centred in a 32pt row and drawn straight over the row below it.
            control.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 6),
            control.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
            text.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 6),
            text.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6)
        ])

        fitToContent(view)
        return view
    }

    /// Ties a row's controls to the label beside them.
    ///
    /// The label sat next to the switch and nothing said they belonged
    /// together, so VoiceOver announced every switch on every page as
    /// "switch" -- read from the window's accessibility tree, where they had
    /// no description at all. A title element is how AppKit links a label to
    /// the control it names. Push buttons are skipped: "Record Shortcut"
    /// already says what it is, and renaming it after the row would hide
    /// that. A threshold row is a stepper and a switch in one view, so the
    /// search goes down through it.
    private static func nameControls(in view: NSView, by label: NSTextField) {
        if let control = view as? NSControl {
            let titled = (control as? NSButton).map {
                !($0 is NSPopUpButton) && !$0.title.isEmpty
            } ?? false
            if !titled, control.accessibilityTitleUIElement() == nil,
               (control.accessibilityLabel() ?? "").isEmpty {
                control.setAccessibilityTitleUIElement(label)
            }
        }
        view.subviews.forEach { nameControls(in: $0, by: label) }
    }

    /// A row that is only a control, spanning the width.
    static func row(_ control: NSView) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(control)
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            control.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // The row is as tall as what is in it. Centring alone says where
            // the control sits and nothing about how much room it needs, so
            // a tall control -- the Clipboard page's list of ignored apps --
            // was centred inside a 28pt row, drawn over the row above it and
            // cut off by the card. It survived while the row's height was
            // merely ambiguous and the engine happened to pick a tall one;
            // `fitToContent` then asked for the shortest height the
            // constraints allowed, and these are the constraints that were
            // missing.
            control.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 6),
            control.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6)
        ])
        fitToContent(view)
        return view
    }

    /// A row that hands its caption the width it has to wrap in.
    ///
    /// A wrapping `NSTextField` asks `preferredMaxLayoutWidth` how wide it may
    /// be, and a label built by `wrappingLabelWithString` starts with that at
    /// zero -- it has no width until something gives it one. A section's
    /// footer gets one from a constraint against the card, which is why
    /// footers have always wrapped to the full width. The captions under a
    /// row's label never had the equivalent, because the width they want is
    /// whatever the control beside them leaves over, and that is not known
    /// until the control has been measured.
    ///
    /// So it is measured here instead of constrained. Two earlier attempts
    /// tied the caption's trailing edge to the control's leading edge, and
    /// both had to come out: the text and the control share a row, so any
    /// constraint between them also moves the control, and it dragged the
    /// right-hand values of the threshold rows out of line with each other.
    /// Setting the width in `layout()` adds no constraint at all, so nothing
    /// but the caption's own line breaks can change.
    private final class DetailRow: NSView {
        weak var caption: NSTextField?
        weak var control: NSView?
        var indent: CGFloat = 0

        override func layout() {
            if let caption, bounds.width > 0 {
                // `fittingSize`, not the control's frame: the control holds
                // its width at required priority, so this is the width it
                // will have, and it does not depend on this pass having laid
                // the control out already.
                let taken = (control?.fittingSize.width ?? 0) + 12 + indent
                // A floor, so a row whose control is unusually wide gives the
                // caption a readable measure rather than a column of one word.
                let width = max(180, bounds.width - taken)
                if abs(caption.preferredMaxLayoutWidth - width) > 0.5 {
                    caption.preferredMaxLayoutWidth = width
                    caption.invalidateIntrinsicContentSize()
                }
            }
            super.layout()
        }
    }

    /// Makes a view as short as its own constraints allow.
    ///
    /// Every row here states a *minimum* height and centres its content with
    /// inequalities, which says what a row may not be and never what it is.
    /// A height nothing determines is one the layout engine may satisfy at
    /// any value, so a row given slack by whatever is above it simply grows:
    /// the Keyboard card opened with 160 points of nothing over its first
    /// shortcut and 200 more under it, while the two rows below -- same
    /// builder, same constraints -- sat at their natural height.
    ///
    /// A zero-height constraint at a priority everything else beats resolves
    /// it. The row collapses to the tallest thing it actually contains, and
    /// slack from above has nowhere to land. `ScrollingPage` already does
    /// this to the page itself; the rows and cards inside it were left
    /// ambiguous.
    static func fitToContent(_ view: NSView) {
        let shortest = view.heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .defaultLow
        shortest.isActive = true
    }

    // MARK: - Controls

    static func toggle(_ on: Bool, _ changed: @escaping (Bool) -> Void) -> NSSwitch {
        let control = ActionSwitch()
        control.controlSize = .mini
        control.state = on ? .on : .off
        control.onChange = changed
        return control
    }

    /// `options` is (title, value); the value is what gets stored.
    static func choice(_ options: [(String, String)], selected: String,
                       _ changed: @escaping (String) -> Void) -> NSPopUpButton {
        let control = ActionPopUp()
        control.controlSize = .small
        control.values = options.map { $0.1 }
        control.onChange = changed
        for (title, value) in options {
            // Localised here rather than at every call site: a choice's
            // options are pairs of (what to show, what to store), and only
            // the first is ever read by a person. Doing it in one place is
            // also what stops half the pickers in an app being translated.
            //
            // `localized` falls back to its argument, so an option whose
            // title is a number -- the process counts are "5", "8", "12" --
            // passes through untouched and needs no key.
            control.addItem(withTitle: localized(title))
            if value == selected { control.select(control.lastItem) }
        }
        return control
    }

    /// A switch with a percentage beside it, for a threshold.
    ///
    /// The two belong together: a threshold with its switch off has no
    /// percentage worth reading, and one with no switch is a number that
    /// cannot be turned off. The stepper is disabled rather than hidden while
    /// the switch is off, so the row does not change width as it is used.
    static func threshold(on: Bool, value: Int,
                          suffix: String = "%",
                          range: ClosedRange<Int> = 1...100,
                          step: Int = 1,
                          _ changed: @escaping (Bool, Int) -> Void) -> NSView {
        let figure = NSTextField(labelWithString: "\(value)\(suffix)")
        figure.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                 weight: .regular)
        figure.textColor = .secondaryLabelColor
        figure.alignment = .right
        figure.translatesAutoresizingMaskIntoConstraints = false

        let stepper = ActionStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(max(1, step))
        stepper.integerValue = value
        stepper.controlSize = .small
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let switcher = ActionSwitch()
        switcher.controlSize = .mini
        switcher.state = on ? .on : .off
        switcher.translatesAutoresizingMaskIntoConstraints = false

        stepper.isEnabled = on
        figure.textColor = on ? .labelColor : .tertiaryLabelColor

        switcher.onChange = { state in
            stepper.isEnabled = state
            figure.textColor = state ? .labelColor : .tertiaryLabelColor
            changed(state, stepper.integerValue)
        }
        stepper.onChange = { stepped in
            figure.stringValue = "\(stepped)\(suffix)"
            changed(switcher.state == .on, stepped)
        }

        let row = NSStackView(views: [figure, stepper, switcher])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for the longest figure the range can produce, so a
        // row does not change width as it is stepped.
        let widest = "\(range.upperBound)\(suffix)"
        figure.widthAnchor.constraint(
            equalToConstant: max(38, (widest as NSString).size(
                withAttributes: [.font: figure.font as Any]).width + 4)
        ).isActive = true
        return row
    }

    /// Which shapes a module draws in the menu bar: one row, "Shows as", with
    /// a pop-up menu whose items picture each shape.
    ///
    /// It was a switch per shape -- nine rows on the Disk page reading Name,
    /// Figure, Line chart... which asked somebody to picture a "Gauge" before
    /// choosing one -- then a grid of tiles drawing them, which fixed that
    /// and took a quarter of the screen. The menu keeps the pictures, drawn
    /// by the menu bar's own `MenuBarWidget`, and costs one row.
    ///
    /// `label` is what the module puts in the menu bar -- "SSD", "CPU" -- so
    /// the Name item shows that word and not a placeholder.
    ///
    /// `value` is the sample figure -- "62°" for a temperature reads as one,
    /// where "42%" would not -- and `title` is for a module that names its
    /// shapes in its own words.
    static func shapes(_ styles: [MenuBarStyle], shown: Set<MenuBarStyle>, label: String,
                       value: String = "42%",
                       title: @escaping (MenuBarStyle) -> String = { $0.title },
                       _ changed: @escaping (Set<MenuBarStyle>) -> Void) -> NSView {
        // A row with a pop-up menu, not a grid of tiles: the grid took a
        // quarter of a screen to choose how one number looks, and the user
        // chose the menu over both a compact and a larger grid. The menu's
        // items still carry each shape's picture -- see ShapeMenu.
        row(localized("Shows as"),
            ShapeMenu(styles, shown: shown, label: label, value: value, title: title,
                      changed: changed))
    }

    /// A colour well, its hex code, and a reset, for one of `RoostColors`.
    ///
    /// Both ways in because each is the natural one for somebody: the
    /// picker to find a colour, the code to match one they already have.
    /// They stay in step -- picking writes the code, typing moves the well.
    static func colour(_ which: RoostColors) -> NSView { ColourControl(which) }

    static func button(_ title: String, _ pressed: @escaping () -> Void) -> NSButton {
        let control = ActionButton()
        // Localised here for the same reason choice() is: a button's title is
        // only ever read by a person, and doing it at the five call sites is
        // how four of them end up translated.
        control.title = localized(title)
        control.bezelStyle = .rounded
        control.controlSize = .small
        control.onPress = pressed
        return control
    }

    /// Controls side by side at the end of a row: a status and the button
    /// that changes it, or a set of buttons that belong together.
    static func group(_ views: [NSView], spacing: CGFloat = 6) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A small heading inside a card, over the rows it names -- a sensor
    /// family. Left-aligned and spaced out, so it reads as a heading and not
    /// as the right-aligned value `label` is for, which it was drawn as.
    static func subheading(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text.uppercased())
        field.font = .systemFont(ofSize: 10.5, weight: .semibold)
        field.textColor = .tertiaryLabelColor
        field.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [.kern: 0.8, .font: field.font as Any,
                         .foregroundColor: NSColor.tertiaryLabelColor])
        field.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        return view
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

// MARK: - Steps

/// Numbered steps side by side: what happens, in the order it happens.
///
/// For a page whose rows are actions rather than settings. A row says what
/// one button does; it cannot say what happens *after* the button, and that
/// is the question that stopped people pressing them -- "Uninstall…" read as
/// though it would delete something on the spot, when it opens a list and
/// asks first. Three short steps answer it before the click, where a footer
/// under the last card was read after it, if at all.
final class StepStrip: NSStackView {

    /// The step titles, for a page whose steps name a key that can change --
    /// the search's shortcut, when another app holds it.
    private(set) var titles: [NSTextField] = []

    init(_ steps: [(title: String, detail: String)], tint: NSColor) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        distribution = .fillEqually
        spacing = 16
        translatesAutoresizingMaskIntoConstraints = false

        for (index, step) in steps.enumerated() {
            let number = NSImageView()
            // The numbered circles go up to 50; a strip is three or four.
            number.image = NSImage(systemSymbolName: "\(index + 1).circle.fill",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
            number.contentTintColor = tint
            number.setContentHuggingPriority(.required, for: .horizontal)

            let title = NSTextField(labelWithString: step.title)
            title.font = .systemFont(ofSize: 12.5, weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titles.append(title)

            let head = NSStackView(views: [number, title])
            head.orientation = .horizontal
            head.alignment = .centerY
            head.spacing = 6

            let detail = NSTextField(wrappingLabelWithString: step.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let column = NSStackView(views: [head, detail])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            column.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(column)
            // The width a wrapping label needs is the column's, said as a
            // constraint -- the way a section's footer gets its own. Without
            // it the caption has no width to wrap in and runs on one line
            // under its neighbours.
            detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            head.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        }
        edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Surfaces

/// A section's card.
///
/// Its colours are set in `updateLayer` rather than once at creation, which
/// is what the plain layer it replaces did: a CGColor is resolved against the
/// appearance at the moment it is made, so switching to Dark Mode left every
/// card the light-mode grey until the pane was rebuilt.
private final class Card: NSStackView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = RoostMetrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // The two display settings are read on every draw, so the card has
        // to be told to draw again when either changes.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private var observer: NSObjectProtocol?

    /// The same three cases as the SwiftUI `Surface`, so a settings card and
    /// a Dashboard card change together: Increase Contrast draws the hairline
    /// at full strength, and Reduce Transparency fills the card opaque rather
    /// than tinting the glass behind it.
    override func updateLayer() {
        super.updateLayer()
        let display = NSWorkspace.shared
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = display.accessibilityDisplayShouldReduceTransparency
                ? NSColor.controlBackgroundColor.cgColor
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
            layer?.borderColor = display.accessibilityDisplayShouldIncreaseContrast
                ? NSColor.separatorColor.cgColor
                : NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        }
    }
}

/// The rounded, tinted square behind a section's symbol.
private final class TintTile: NSView {
    private let tint: NSColor

    init(_ tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5.5
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.cgColor
        }
    }
}

// MARK: - Controls that carry their own action

/// Target/action is an Objective-C mechanism and forces every control's
/// handler onto the view that built it. These three keep their own closure,
/// which is what lets a pane be a list of rows rather than a list of rows plus
/// a parallel list of @objc methods.
final class ActionSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { onChange?(state == .on) }
}

final class ActionPopUp: NSPopUpButton {
    var onChange: ((String) -> Void)?
    /// Parallel to the menu items: what each title means when stored.
    var values: [String] = []
    convenience init() { self.init(frame: .zero, pullsDown: false) }
    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() {
        guard values.indices.contains(indexOfSelectedItem) else { return }
        onChange?(values[indexOfSelectedItem])
    }
}

final class ActionStepper: NSStepper {
    var onChange: ((Int) -> Void)?
    convenience init() { self.init(frame: .zero) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.valueWraps = false
        self.autorepeat = true
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { onChange?(integerValue) }
}

final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { onPress?() }
}

/// See `Controls.colour`.
private final class ColourControl: NSStackView, NSTextFieldDelegate {

    private let which: RoostColors
    private let well = NSColorWell()
    private let field = NSTextField()
    private let reset = ActionButton()

    init(_ which: RoostColors) {
        self.which = which
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false

        well.colorWellStyle = .minimal
        well.color = which.color
        well.target = self
        well.action = #selector(picked)
        well.translatesAutoresizingMaskIntoConstraints = false

        field.stringValue = which.hex
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.controlSize = .small
        field.alignment = .center
        field.placeholderString = which.defaultHex
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                              accessibilityDescription: "Restore the default colour")
        reset.isBordered = false
        reset.toolTip = "Restore \(which.defaultHex)"
        reset.onPress = { [weak self] in self?.apply(nil) }
        reset.translatesAutoresizingMaskIntoConstraints = false

        for view in [reset, field, well] { addArrangedSubview(view) }
        NSLayoutConstraint.activate([
            // Measured: "#WWWWWW" in the small monospaced face is 58pt, and
            // the field's own insets need the rest.
            field.widthAnchor.constraint(equalToConstant: 72),
            well.widthAnchor.constraint(equalToConstant: 38),
            well.heightAnchor.constraint(equalToConstant: 22),
            reset.widthAnchor.constraint(equalToConstant: 18)
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func picked() {
        // A colour with no sRGB form -- a pattern from the picker's image tab
        // -- is ignored rather than stored as a guess.
        guard let hex = RoostColors.hex(of: well.color) else { return }
        apply(hex)
    }

    /// Return or leaving the field. A code that is not a colour puts the
    /// current one back rather than storing nothing.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let clean = RoostColors.normalised(field.stringValue) else {
            NSSound.beep()
            sync()
            return
        }
        apply(clean)
    }

    private func apply(_ hex: String?) {
        which.set(hex: hex)
        sync()
    }

    private func sync() {
        field.stringValue = which.hex
        // Only when it differs: setting a well's colour while its panel is
        // dragging restarts the drag.
        if RoostColors.hex(of: well.color) != which.hex { well.color = which.color }
        // Hidden rather than disabled: a greyed arrow on every row read as
        // clutter. It is the leftmost item and the row is pinned at its
        // trailing edge, so nothing else moves when it comes and goes.
        reset.isHidden = !which.isCustom
    }
}

// MARK: - Shape picker
