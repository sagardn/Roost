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

        // A column like every other settings page, scrolled and held to a
        // readable width by `ScrollingPage`. It had a scroll view of its
        // own, which nothing held to `maxContentWidth`: on a wide window each
        // switch sat a thousand points from the setting it belonged to.
        orientation = .vertical
        alignment = .leading
        spacing = RoostMetrics.sectionSpacing
        edgeInsets = NSEdgeInsets(top: RoostMetrics.pageTop, left: RoostMetrics.pageInset,
                                  bottom: RoostMetrics.pageInset, right: RoostMetrics.pageInset)

        // Grouped the way System Settings groups its own: how Roost starts
        // and what it looks like, then keeping it up to date, then the menu
        // bar and its colours, then the things somebody comes here once
        // for -- a permission, a backup, the manual. The version card that
        // headed the page went: the sidebar names the app and its version,
        // and the version belongs beside the button that checks for a newer
        // one.
        for section in [general(), updates(), menuBar(), colours(), permissions(), backup(), help()] {
            addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: widthAnchor,
                                           constant: -RoostMetrics.pageInset * 2).isActive = true
        }

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

    private func general() -> NSView {
        // Switches first, then the menu, so like controls line up.
        Controls.section(localized("General"), symbol: "gearshape.fill", tint: .systemGray, [
            Controls.row(localized("Start at login"), launchAtLoginToggle()),
            Controls.row(localized("Show in Dock"), Controls.toggle(prefs.dockIcon) { [weak self] on in
                self?.prefs.dockIcon = on
                NSApp.setActivationPolicy(on ? .regular : .accessory)
            }, detail: localized("Also gives Roost a menu bar of its own while it is in front.")),
            Controls.row(localized("Temperature unit"), Controls.choice(
                [(localized("System"), "system"), (localized("Celsius"), "celsius"),
                 (localized("Fahrenheit"), "fahrenheit")],
                selected: prefs.temperatureUnits) { [weak self] value in
                    self?.prefs.temperatureUnits = value
                })
        ])
    }

    /// The version, a way to check now, and how often to check by itself.
    ///
    /// A section of its own. The schedule sat between Show in Dock and the
    /// temperature unit, under a caption -- "The last choice replaces Roost
    /// with the new version without asking" -- that only made sense to
    /// somebody who had opened the menu and counted to its last item.
    private func updates() -> NSView {
        let version = Controls.label(Version.current.map { "\($0)" } ?? "—")
        let check = Controls.button(localized("Check Now")) { [weak self] in self?.checkForUpdate() }
        return Controls.section(localized("Updates"), symbol: "arrow.down.circle.fill", tint: .systemBlue, [
            Controls.row(localized("Roost version"), Controls.group([version, check])),
            // Built from the schedule itself. It was a hand-written list
            // that offered "Once per hour", which the scheduler has no case
            // for -- so picking it switched update checks off without a word.
            Controls.row(localized("Check for updates"), Controls.choice(
                UpdateInterval.offered.map { ($0.title, $0.rawValue) },
                selected: UpdateInterval.interval(from: prefs.updateInterval)?.rawValue ?? prefs.updateInterval) { [weak self] value in
                    self?.prefs.updateInterval = value
                }, detail: localized("Roost checks GitHub for a new version. Only the last choice installs one without asking."))
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
        }, indented: true, detail: localized("A thin line between the modules."))
        let details = Controls.row(localized("One popup for all"), Controls.toggle(prefs.combinedPopup) { [weak self] on in
            self?.prefs.combinedPopup = on
        }, indented: true, detail: localized("Clicking anywhere on the item opens one popup with every module, instead of the one you clicked."))
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
            // "Keep item positions" was here. Nothing read it: every item
            // has an `autosaveName`, so macOS keeps a ⌘-dragged position
            // whatever the switch said, and a switch that changes nothing
            // teaches a person that switches here may not work.
            spacing, separator, details
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
            Controls.row(localized("Busy"), Controls.colour(.warning),
                         detail: localized("Also the colour of uploads and disk writes in charts.")),
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
        // Reset on a row of its own, under what it does. Beside Export and
        // Import it was one more button of the same size, and the one that
        // cannot be undone deserves a sentence before it is pressed.
        return Controls.section(localized("Backup and reset"), symbol: "archivebox.fill", tint: .systemIndigo, [
            Controls.row(localized("Settings file"), Controls.group([
                Controls.button("Export…") { [weak self] in self?.export() },
                Controls.button("Import…") { [weak self] in self?.importSettings() }
            ]), detail: localized("Save every setting to a file, or bring them back from one.")),
            Controls.row(localized("Reset all settings"), reset,
                         detail: localized("Puts every setting back to how Roost came, then restarts it. Clipboard history is kept.")),
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
        return WindowControl.wasRevoked ? localized("Needs allowing again after the update")
                                        : localized("Not allowed")
    }

    private func launchAtLoginToggle() -> NSSwitch {
        let control = Controls.toggle(LoginItem.isEnabled) { [weak self] on in
            LoginItem.isEnabled = on
            // Refused for a bundle running out of a build folder, so the
            // switch must not sit there claiming it took.
            if on && !LoginItem.isEnabled {
                self?.launchAtLoginSwitch?.state = .off
                // Said as what to do. The folder Roost was running from is
                // a build path nobody else needs to read; it is one click
                // away in Finder.
                Alert.show(localized("Move Roost to Applications first"),
                           localized("Roost can only start at login from your Applications folder. Drag Roost into Applications, open it from there, then turn this on again."),
                           asks: false, actionTitle: localized("Show Roost in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
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
                // The app's one update window. A new one per click gave two
                // windows that could both download, held by nothing.
                let window = (NSApp.delegate as? AppDelegate)?.ensureUpdateWindow() ?? UpdateWindow(updater: appUpdater)
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
                       asks: false, actionTitle: "Restart now") { [weak self] in self?.onRestartNeeded() }
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
