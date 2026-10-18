import AppKit
import UserNotifications

/// The Settings pane: how Roost behaves, how the menu bar is arranged, how the
/// search and switcher work, and what to do with the settings themselves.
///
/// Replaces `Roost/Views/AppSettings.swift`. Every preference is read and
/// written through `Preferences`, under the same keys, so nothing a user has
/// set is lost.
///
/// Built as a list of rows with closures rather than a class of `@objc`
/// handlers. The pane it replaces carried twenty-two selector methods, a
/// stored property per control so those methods could find them again, and a
/// `setRowVisibility(_:newState:)` call per row addressed by *index* — change
/// the order of the rows and the wrong ones hide. Rows here hold their own
/// behaviour and visibility.
/// A stack whose coordinates start at the top.
///
/// An NSScrollView whose document view is not flipped puts the origin at the
/// bottom, so it opens showing the *end* of the content. The pane looked as
/// though it was clipping the app icon; it was scrolled past it. Four attempts
/// at the image view went nowhere because the image was never the problem.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class GeneralPane: NSStackView {

    private let prefs = Preferences.shared
    private let onRestartNeeded: () -> Void

    /// Rows whose visibility depends on another setting, kept by name.
    private var dependent: [String: NSView] = [:]
    private var accessibilityStatus: NSTextField?
    private var accessibilityButton: NSButton?
    private var notificationStatus: NSTextField?
    private var launchAtLoginSwitch: ActionSwitch?

    init(width: CGFloat, onRestartNeeded: @escaping () -> Void = {}) {
        self.onRestartNeeded = onRestartNeeded
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        self.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let column = FlippedStack()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        // `contentTop`, not 44: the 44 was for a title bar the detail view
        // scrolled under, but it is now placed below the toolbar already,
        // and the two together left a 100pt band above the first card.
        column.edgeInsets = NSEdgeInsets(top: RoostMetrics.contentTop, left: 18, bottom: 18, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false

        // Each section is pinned to the column's width. Without this a stack
        // with .leading alignment gives every card its natural width, so the
        // cards came out ~380pt wide inside a 1,100pt pane and labels
        // truncated while most of the pane sat empty.
        // Ordered by how often each is reached for: how Roost starts, then
        // how it looks, then the things somebody comes here once for -- a
        // permission, a backup, the welcome tour. The launcher's rows have
        // a page of their own now, Search & switcher in the sidebar.
        let sections = [identity(), general(), menuBar(), colours(),
                        permissions(), backup(), help()]
        for section in sections {
            column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: column.widthAnchor,
                                           constant: -(column.edgeInsets.left + column.edgeInsets.right)
                                          ).isActive = true
        }

        // The column *is* the document, and only its width is tied to the
        // scroll view. Wrapping it in a container pinned on all four edges
        // forced the content to the height of the visible area -- the stack
        // then had less room than its subviews needed and clipped the first
        // one, which is why the app icon arrived as the bottom third of
        // itself. A scrolling column must be free to be taller than its
        // clip view; that is the entire point of it.
        scroll.documentView = column
        column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        self.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalTo: self.heightAnchor).isActive = true

        syncDependentRows()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called when the pane comes back on screen: the two states that can
    /// change behind its back.
    func viewWillAppear() {
        syncAccessibility()
        launchAtLoginSwitch?.state = LoginItem.isEnabled ? .on : .off
    }

    // MARK: - Sections

    /// Icon, name and version on one line, with the update button at its end.
    ///
    /// A row rather than the centred 96pt icon over three lines it replaces,
    /// which took 200pt -- a fifth of the window -- before the first setting.
    private func identity() -> NSView {
        let icon = NSImageView()
        icon.image = Self.appIcon(40)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let name = NSTextField(labelWithString: "Roost")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let version = NSTextField(labelWithString: Version.current.map { "Version \($0)" } ?? "")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true

        let words = NSStackView(views: [name, version])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1

        let update = Controls.button("Check for update") { [weak self] in self?.checkForUpdate() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, words, spacer, update])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        // On a card like every section under it, so the page reads as one
        // set of surfaces rather than a loose header over a stack of them.
        return Controls.section(nil, [row])
    }

    private func general() -> NSView {
        // Switches first, then the two menus, so like controls line up.
        Controls.section(localized("General"), symbol: "gearshape.fill", tint: .systemGray, [
            Controls.row(localized("Start at login"), launchAtLoginToggle()),
            Controls.row(localized("Show in Dock"), Controls.toggle(prefs.dockIcon) { [weak self] on in
                self?.prefs.dockIcon = on
                NSApp.setActivationPolicy(on ? .regular : .accessory)
            }),
            Controls.row(localized("Check for updates"), Controls.choice(
                [("Never", "Never"), ("Once per hour", "Once per hour"),
                 ("Once per day", "Once per day"), ("Once per week", "Once per week"),
                 ("Silent", "Silent")],
                selected: prefs.updateInterval) { [weak self] value in
                    self?.prefs.updateInterval = value
                }),
            Controls.row(localized("Temperature unit"), Controls.choice(
                [("System", "system"), ("Celsius", "celsius"), ("Fahrenheit", "fahrenheit")],
                selected: prefs.temperatureUnits) { [weak self] value in
                    self?.prefs.temperatureUnits = value
                })
        ])
    }

    private func menuBar() -> NSView {
        let spacing = Controls.row(localized("Spacing"), Controls.choice(
            [("None", "none"), ("Small", "small"), ("Normal", "normal"), ("Large", "large")],
            selected: prefs.combinedSpacing) { [weak self] value in
                self?.prefs.combinedSpacing = value
            }, indented: true)
        let separator = Controls.row(localized("Separators"), Controls.toggle(prefs.combinedSeparator) { [weak self] on in
            self?.prefs.combinedSeparator = on
        }, indented: true)
        let details = Controls.row(localized("One popup for all"), Controls.toggle(prefs.combinedPopup) { [weak self] on in
            self?.prefs.combinedPopup = on
        }, indented: true)
        dependent["combined.spacing"] = spacing
        dependent["combined.separator"] = separator
        dependent["combined.details"] = details

        // Combine first, so the rows that only exist while it is on sit
        // directly under it rather than under the unrelated position switch.
        return Controls.section(localized("Menu bar"), symbol: "menubar.rectangle", tint: .systemBlue,
                                footer: localized("How the readings sit in the menu bar. What each one shows is set on its own page."), [
            Controls.row(localized("Combine modules into one item"),
                         Controls.toggle(prefs.combinedModules) { [weak self] on in
                             self?.prefs.combinedModules = on
                             self?.syncDependentRows()
                         }),
            spacing, separator, details,
            Controls.row(localized("Keep item positions"),
                         Controls.toggle(prefs.keepMenuBarPositions) { [weak self] on in
                             self?.prefs.keepMenuBarPositions = on
                         })
        ])
    }

    /// The three load colours, everywhere they are used at once: the menu
    /// bar figures, the popups' status dots, bars and charts. Amber is also
    /// the upload series, which the label says rather than leaving a user
    /// to wonder why their arrows changed.
    private func colours() -> NSView {
        Controls.section(localized("Colours"), symbol: "paintpalette.fill", tint: .systemOrange,
                         footer: localized("Used by the menu bar figures and by every popup's dots, bars and charts."), [
            Controls.row(localized("Colour the menu bar"),
                         Controls.toggle(RoostColors.menuBarColoured) { RoostColors.menuBarColoured = $0 }),
            Controls.row(localized("Normal"), Controls.colour(.calm)),
            Controls.row(localized("Busy · upload and write"), Controls.colour(.warning)),
            Controls.row(localized("Critical"), Controls.colour(.critical))
        ])
    }

    /// Every permission Roost asks for, what it is for, and where it stands.
    ///
    /// Each row names the feature before the permission, because nobody
    /// grants "Accessibility" -- they want the switcher to work -- and says
    /// what happens without it. Window control is also on the Search &
    /// switcher page, beside the thing that needs it.
    private func permissions() -> NSView {
        let status = Controls.label(Self.accessibilityState)
        accessibilityStatus = status
        let allow = Controls.button("Allow…") { [weak self] in
            Launcher.shared.grantAccessibility()
            self?.syncAccessibility()
        }
        accessibilityButton = allow

        let alerts = Controls.label("")
        notificationStatus = alerts
        let openAlerts = Controls.button("Notification settings…") {
            Self.openNotificationSettings()
        }

        let section = Controls.section(localized("Permissions"), symbol: "lock.shield.fill",
                                       tint: .systemGreen,
                                       footer: localized("Roost reads nothing else that needs asking. Nothing it reads leaves this Mac."), [
            // The state and the way to change it on one row, rather than a
            // status row and a full-width button bar under it.
            Controls.row(localized("Window control"), Controls.group([status, allow]),
                         detail: localized("Accessibility access, which the switcher needs to bring windows forward.")),
            Controls.row(localized("Alerts"), Controls.group([alerts, openAlerts]),
                         detail: localized("Notifications, for the alerts you switch on in each module and for updates."))
        ])
        syncAccessibility()
        return section
    }

    /// Export, import and reset on one row: three actions on one file, not
    /// three settings. Not titled "Settings", which the page already is.
    private func backup() -> NSView {
        let reset = Controls.button("Reset…") { [weak self] in self?.reset() }
        // The title, not contentTintColor: a rounded push button ignores the
        // tint, and the first attempt came out the same grey as its siblings.
        reset.attributedTitle = NSAttributedString(string: localized("Reset…"), attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        return Controls.section(localized("Backup"), symbol: "archivebox.fill", tint: .systemIndigo, [
            Controls.row(localized("Your settings"), Controls.group([
                Controls.button("Export…") { [weak self] in self?.export() },
                Controls.button("Import…") { [weak self] in self?.importSettings() },
                reset
            ])),
            // Next to Export because it is the same kind of thing -- text
            // about this install, for somewhere else. It carries no serial
            // number, network name or address; see Diagnostics.
            Controls.row(localized("Diagnostics"),
                         Controls.button("Copy report") {
                             Diagnostics.copyToPasteboard()
                             Notify.show(localized("Diagnostics copied"),
                                         symbol: "doc.on.clipboard")
                         },
                         detail: localized("For a bug report. No serial number, network name or address."))
        ])
    }

    /// The first-run tour, again. It changes nothing by being walked
    /// through: every choice in it starts on the current setting and writes
    /// only when clicked, so reopening it is safe for somebody who has set
    /// Roost up just how they like it.
    private func help() -> NSView {
        Controls.section(localized("Help"), symbol: "questionmark.circle.fill", tint: .systemBlue, [
            Controls.row(localized("Welcome tour"),
                         Controls.button("Show again…") {
                             (NSApp.delegate as? AppDelegate)?.ensureSetupWindow().show()
                         },
                         detail: localized("The launcher's keys, the presets and the permissions, one page each.")),
            Controls.row(localized("User manual"),
                         Controls.button("Open…") {
                             if let url = AppLinks.manualURL { NSWorkspace.shared.open(url) }
                         },
                         detail: localized("Every setting and keyboard shortcut, on the project's site."))
        ])
    }

    // MARK: - Behaviour

    /// The app icon drawn into a bitmap of exactly `side` points.
    ///
    /// Neither `imageScaling` nor setting the image's `size` fixed this: the
    /// asset catalogue hands back a 1024pt image whose representations are
    /// drawn at their own size, and every scaling mode still produced the
    /// bottom third of the icon in a 96pt box. Rasterising it once at the size
    /// it is displayed at removes the question.
    private static func appIcon(_ side: CGFloat) -> NSImage? {
        guard let source = NSImage(named: NSImage.Name("AppIcon")) else { return nil }
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
    }

    /// The button goes once there is nothing left to allow.
    private func syncAccessibility() {
        accessibilityStatus?.stringValue = Self.accessibilityState
        accessibilityButton?.isHidden = WindowControl.isTrusted
        syncNotifications()
    }

    /// Asked of the system, which answers on its own queue.
    private func syncNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: text = localized("Allowed")
            case .denied:                   text = localized("Not allowed")
            // Asked for the first time an alert fires, not before: a
            // permission prompt for alerts nobody has switched on is noise.
            default:                        text = localized("Asked when an alert is first due")
            }
            DispatchQueue.main.async { self?.notificationStatus?.stringValue = text }
        }
    }

    private static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.sagar.roost"
        for address in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                        "x-apple.systempreferences:com.apple.preference.notifications"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    static var accessibilityState: String {
        if WindowControl.isTrusted { return localized("Allowed") }
        return WindowControl.wasRevoked ? localized("Allowed, but stale since the update")
                                        : localized("Not allowed")
    }

    private func launchAtLoginToggle() -> NSSwitch {
        let control = Controls.toggle(LoginItem.isEnabled) { [weak self] on in
            LoginItem.isEnabled = on
            // Refused for a bundle running out of a build folder, so the
            // switch must not sit there claiming it took.
            if on && !LoginItem.isEnabled {
                self?.launchAtLoginSwitch?.state = .off
                Alert.show("Move Roost to /Applications first",
                           "Roost is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path). "
                           + "A login item pointing there starts a copy that the next build replaces, "
                           + "which makes macOS ask for Accessibility again at every login.")
            }
        }
        launchAtLoginSwitch = control as? ActionSwitch
        return control
    }

    /// Rows that only mean something while another setting is on.
    private func syncDependentRows() {
        let combined = prefs.combinedModules
        for name in ["combined.spacing", "combined.separator", "combined.details"] {
            dependent[name]?.isHidden = !combined
        }
    }

    private func checkForUpdate() {
        appUpdater.check { [weak self] result in
            DispatchQueue.main.async {
                guard self != nil else { return }
                let window = UpdateWindow(updater: appUpdater)
                switch result {
                case .success(.available(let release)): window.offer(release)
                case .success(.upToDate):               window.reportUpToDate()
                case .failure(let error):               window.report(error)
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Roost settings.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try prefs.exportAll().write(to: url)
        } catch {
            Alert.show("Could not save the settings", error: error)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try prefs.importAll(Data(contentsOf: url))
            Alert.show("Imported \(count) settings",
                       "Roost needs to restart for all of them to take effect.",
                       actionTitle: "Restart now") { [weak self] in self?.onRestartNeeded() }
        } catch {
            Alert.show("That is not a Roost settings file", error: error)
        }
    }

    private func reset() {
        Alert.show("Reset every setting?",
                   "Roost will go back to its defaults and restart. This cannot be undone.",
                   style: .warning,
                   actionTitle: "Reset") { [weak self] in
            self?.prefs.resetAll()
            self?.onRestartNeeded()
        }
    }
}
