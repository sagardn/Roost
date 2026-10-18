import AppKit

/// How a module draws in the menu bar, chosen from a pop-up menu.
///
/// A menu rather than a grid of tiles, at the user's choice: the grid took a
/// quarter of a screen to choose how one number looks, and a bigger grid was
/// the other direction asked for. The menu costs one row of the page and
/// still shows every shape before it is picked -- each item carries a small
/// picture of the shape, drawn by the menu bar's own widget from a sample
/// reading, so what is in the menu is what will be in the menu bar.
///
/// Several shapes can be on at once; they sit side by side. The last one
/// cannot be turned off -- a module with nothing in the menu bar is a module
/// switched off, and that is the switch at the top of the page.
final class ShapeMenu: NSView {

    private let styles: [MenuBarStyle]
    private var shown: Set<MenuBarStyle>
    private let title: (MenuBarStyle) -> String
    private let changed: (Set<MenuBarStyle>) -> Void
    private let button = NSPopUpButton(frame: .zero, pullsDown: true)

    init(_ styles: [MenuBarStyle], shown: Set<MenuBarStyle>, label: String, value: String,
         title: @escaping (MenuBarStyle) -> String, changed: @escaping (Set<MenuBarStyle>) -> Void) {
        self.styles = styles
        self.shown = shown
        self.title = title
        self.changed = changed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])

        // A pull-down's first item is its title, never a choice.
        button.addItem(withTitle: "")
        let sample = Self.sample(label: label, value: value)
        for style in styles {
            let item = NSMenuItem(title: title(style), action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.image = Self.preview(style, sample)
            button.menu?.addItem(item)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pick(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let style = MenuBarStyle(rawValue: raw) else { return }
        if shown.contains(style) {
            guard shown.count > 1 else { NSSound.beep(); return }
            shown.remove(style)
        } else {
            shown.insert(style)
        }
        refresh()
        changed(shown)
    }

    private func refresh() {
        for item in button.itemArray.dropFirst() {
            let style = (item.representedObject as? String).flatMap(MenuBarStyle.init(rawValue:))
            item.state = style.map(shown.contains) == true ? .on : .off
        }
        // The chosen shapes, in the order they sit in the menu bar.
        let names = styles.filter(shown.contains).map(title)
        button.itemArray.first?.title = names.joined(separator: ", ")
        button.toolTip = names.joined(separator: ", ")
        button.setAccessibilityLabel(localized("Menu bar") + ": " + names.joined(separator: ", "))
    }

    /// The shape drawn by the menu bar's own widget, on the menu bar's own
    /// ground, at menu bar size.
    private static func preview(_ style: MenuBarStyle, _ sample: MenuBarReading) -> NSImage? {
        let widget = MenuBarWidget()
        widget.styles = [style]
        widget.content = sample
        let size = NSSize(width: max(1, widget.intrinsicContentSize.width), height: MenuBarMetrics.height)
        widget.frame = NSRect(origin: .zero, size: size)
        widget.appearance = NSApp.effectiveAppearance
        guard let rep = widget.bitmapImageRepForCachingDisplay(in: widget.bounds) else { return nil }
        widget.cacheDisplay(in: widget.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// A reading every shape can draw, busy enough to look like one.
    private static func sample(label: String, value: String) -> MenuBarReading {
        let history = (0..<24).map { 0.35 + 0.25 * sin(Double($0) / 3) }
        var rates = MenuBarReading.Pair("98 KB/s", "1.2 MB/s")
        rates.speeds = .init(upload: 98_000, download: 1_200_000)
        return MenuBarReading(
            label: label, load: 0.42, value: value,
            history: history,
            bars: [0.35, 0.6, 0.25, 0.5],
            segments: [.init(0.42, .roostCalm)],
            pair: .init("120 GB", "60 GB"),
            rates: rates,
            mirrored: .init(up: history.map { $0 * 0.4 }, down: history))
    }
}
