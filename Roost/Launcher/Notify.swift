import AppKit

/// A small HUD for the things that need saying once: an app was added, a
/// window cannot be minimised, Accessibility is missing.
///
/// Deliberately not UserNotifications: that needs the user to grant
/// notification permission, and routes a sentence about a keystroke through
/// Notification Centre, where it arrives late and stays until dismissed. This
/// appears immediately, says one thing, and leaves.
enum Notify {

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// `symbol` is an SF Symbol name. A word plus a glyph is read at a glance;
    /// a bare sentence in the middle of the screen has to be read.
    static func show(_ text: String, symbol: String? = nil, for seconds: TimeInterval = 1.8) {
        DispatchQueue.main.async {
            hideWork?.cancel()
            panel?.orderOut(nil)

            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 9
            row.translatesAutoresizingMaskIntoConstraints = false

            if let symbol,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
                let icon = NSImageView(image: image)
                icon.contentTintColor = .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                row.addArrangedSubview(icon)
            }
            row.addArrangedSubview(label)

            // Glass where the system has it, vibrancy below that. Either way
            // the HUD borrows the desktop behind it instead of sitting on a
            // flat grey slab.
            let ground: NSView
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = 18
                glass.contentView = NSView()
                ground = glass
            } else {
                let effect = NSVisualEffectView()
                effect.material = .hudWindow
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = 18
                effect.layer?.masksToBounds = true
                ground = effect
            }
            ground.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            content.addSubview(ground)
            content.addSubview(row)
            NSLayoutConstraint.activate([
                ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                ground.topAnchor.constraint(equalTo: content.topAnchor),
                ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),

                row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                row.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
            ])

            let size = content.fittingSize
            let hud = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
            hud.contentView = content
            hud.isOpaque = false
            hud.backgroundColor = .clear
            hud.level = .statusBar
            hud.ignoresMouseEvents = true
            hud.hidesOnDeactivate = false
            hud.hasShadow = true
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            guard let screen = NSScreen.main else { return }
            let frame = screen.visibleFrame
            let resting = NSPoint(x: frame.midX - size.width / 2,
                                  y: frame.minY + frame.height * 0.16)
            // Rises into place: movement tells the eye something arrived, so
            // the HUD does not have to shout to be noticed.
            hud.setFrameOrigin(NSPoint(x: resting.x, y: resting.y - 12))
            hud.alphaValue = 0
            hud.orderFrontRegardless()
            panel = hud

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                hud.animator().alphaValue = 1
                hud.animator().setFrame(NSRect(origin: resting, size: size), display: true)
            }

            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    hud.animator().alphaValue = 0
                } completionHandler: {
                    hud.orderOut(nil)
                    if panel === hud { panel = nil }
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}
