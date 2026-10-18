import AppKit

/// Where Roost asks for support, and points at its own repository.
///
/// Replaces `Roost/Views/Support.swift`. Same window, same two destinations,
/// built with constraints and Roost's own `localized`, `AppLinks` and link
/// buttons — the view it replaces borrowed `SupportButtonView` from
/// `Setup.swift`, which is not ours yet, so a rebuilt view would have stayed
/// coupled to code on its way out.
///
/// The window sizes itself to its text rather than to a fixed 460×340. The
/// support message is translated into 42 languages and several of them are
/// considerably longer than English, which the fixed frame clipped.
final class SupportWindow: NSWindow, NSWindowDelegate {

    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                   styleMask: [.closable, .titled, .fullSizeContentView],
                   backing: .buffered,
                   defer: true)

        self.title = localized("Support Roost")
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        self.delegate = self

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = backdrop

        let message = NSTextField(wrappingLabelWithString: localized("Support text"))
        message.alignment = .center
        // A wrapping label has no height until it has a width to wrap to.
        // Without this the window's fittingSize collapsed to 176x201 and the
        // message was unreadable.
        message.preferredMaxLayoutWidth = 400
        message.font = .systemFont(ofSize: 14)
        message.isSelectable = false
        message.translatesAutoresizingMaskIntoConstraints = false

        var destinations: [NSView] = []
        if let repository = AppLinks.repositoryURL {
            destinations.append(LinkButton(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right") {
                NSWorkspace.shared.open(repository)
            })
        }
        if let donation = AppLinks.donationURL {
            destinations.append(LinkButton(title: localized("Donate"), symbol: "heart.fill") {
                NSWorkspace.shared.open(donation)
            })
        }

        let links = NSStackView(views: destinations)
        links.orientation = .horizontal
        links.distribution = .fillEqually
        links.spacing = 20
        links.translatesAutoresizingMaskIntoConstraints = false

        let close = Controls.button(localized("Close")) { [weak self] in self?.close() }
        close.keyEquivalent = "\r"

        let column = NSStackView(views: [message, links, close])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 20
        column.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 30),
            column.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -30),
            column.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 40),
            column.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -24),
            column.widthAnchor.constraint(equalToConstant: 400),
            message.widthAnchor.constraint(equalTo: column.widthAnchor),
            links.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor)
        ])

        self.setContentSize(backdrop.fittingSize)
        self.center()
        self.setIsVisible(false)
    }

    func show() {
        self.setIsVisible(true)
        self.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }
}

/// A labelled destination: symbol above, title below.
private final class LinkButton: NSButton {
    private let open: () -> Void

    init(title: String, symbol: String, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)

        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageAbove
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        self.title = title
        self.toolTip = title
        self.target = self
        self.action = #selector(fire)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 60).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { open() }
}
