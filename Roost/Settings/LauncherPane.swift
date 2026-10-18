import AppKit

/// The Search & switcher page: the launcher's keys, how its panel behaves,
/// the trackpad gesture, and the list of apps.
///
/// These rows were the fifth section of the Settings page, between the
/// colours and the permissions. Half of what Roost does is the launcher, and
/// a page about the menu bar is not where anybody looks for it. The
/// preferences, their keys and their side effects are exactly what they were
/// there; only the page they are on moved.
///
/// What is new is the Keyboard section. A global key belongs to whichever
/// process registers it first, and until now the only report that another
/// app had ⌃Space was a HUD at launch that was gone in four seconds. The
/// section reads what `Launcher` actually holds, and says so.
final class LauncherPane: NSStackView {

    private var dependent: [String: NSView] = [:]
    private var keyRows: [() -> Void] = []
    private var accessibilityStatus: NSTextField?
    private var accessibilityButton: NSButton?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = RoostMetrics.sectionSpacing
        edgeInsets = NSEdgeInsets(top: RoostMetrics.pageTop, left: RoostMetrics.pageInset,
                                  bottom: RoostMetrics.pageInset, right: RoostMetrics.pageInset)

        for section in [keyboard(), behaviour(), gesture(), permission()] {
            addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: widthAnchor,
                                           constant: -RoostMetrics.pageInset * 2).isActive = true
        }
        syncDependentRows()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The two things that change behind the page's back: a key another app
    /// let go of, and the Accessibility grant.
    func viewWillAppear() {
        keyRows.forEach { $0() }
        syncAccessibility()
    }

    // MARK: - Sections

    private func keyboard() -> NSView {
        let launcher = Launcher.shared

        let search = keyRow(localized("Open the search"),
                            detail: localized("Type to find an app, then Return to switch to it."),
                            state: { launcher.searchKey })
        let minimise = keyRow(localized("Minimise the front app, or bring it back"),
                              state: { launcher.minimizeKey })

        let cycleStatus = Controls.label("")
        let cycleSwitch = Controls.toggle(Prefs.cycleHotkeyEnabled) { [weak self] on in
            Prefs.cycleHotkeyEnabled = on
            Launcher.shared.applyCycleHotkey()
            self?.keyRows.forEach { $0() }
        }
        let refreshCycle = {
            guard let key = Launcher.shared.cycleKey else {
                cycleStatus.stringValue = ""
                return
            }
            cycleStatus.stringValue = key.isActive
                ? (Launcher.shared.cycleFellBack
                    ? localized("%0 — ⌃Tab is taken by another app", key.keys) : key.keys)
                : localized("%0 is taken by another app", key.keys)
        }
        keyRows.append(refreshCycle)
        refreshCycle()
        let cycle = Controls.row(localized("⌃Tab cycles your marked apps"),
                                 Controls.group([cycleStatus, cycleSwitch]),
                                 detail: localized("Add apps to it from an app's options menu in the search. With none added it walks your recent apps."))

        let apps = Controls.row(localized("Your apps"),
                                Controls.button("Edit apps…") { Launcher.shared.editApps() },
                                detail: localized("Reorder them, and give any of them a ⌃ shortcut that switches straight to it."))

        return Controls.section(localized("Keyboard"), symbol: "keyboard.fill", tint: .systemPurple,
                                footer: localized("A key another app registered first stays that app's. Roost does not take it over; it says so here instead."),
                                [search, minimise, cycle, apps])
    }

    private func behaviour() -> NSView {
        Controls.section(localized("Search & switcher"), symbol: "magnifyingglass", tint: .systemPurple, [
            Controls.row(localized("Open where the pointer is"),
                         Controls.toggle(Prefs.openAtPointer) { Prefs.openAtPointer = $0 }),
            Controls.row(localized("Close when it loses focus"),
                         Controls.toggle(Prefs.hideOnOutsideClick) { Prefs.hideOnOutsideClick = $0 }),
            Controls.row(localized("Click an app in front to minimise it"),
                         Controls.toggle(Prefs.clickMinimizes) { Prefs.clickMinimizes = $0 },
                         detail: localized("In the search and with an app's own shortcut. Off, a click only brings an app forward.")),
            // Its own row, not indented under the one above as it was: the
            // two are separate settings in `Prefs`, and the Dock one works
            // with the other switched off -- the indent said otherwise.
            Controls.row(localized("Click an app in the Dock to minimise it"),
                         Controls.toggle(Prefs.dockClickPutsAway) {
                             Prefs.dockClickPutsAway = $0
                             DockWatcher.shared.refresh()
                         },
                         detail: localized("Click it once to bring it forward, again to put it away. Needs window control."))
        ])
    }

    private func gesture() -> NSView {
        // Two fingers is not offered: macOS makes a two-finger tap a secondary
        // click and the pair Smart Zoom, so TapRecognizer refuses anything
        // below three. A row for it would be a switch that cannot turn on.
        let fingerRows = [3, 4].map { count -> NSView in
            // Two whole keys rather than a word slotted into a sentence:
            // "Three" and "-finger double tap" are not separable in every
            // language, and the version that indexed an array of words could
            // not be translated at all.
            let label = count == 3 ? localized("Three-finger double tap")
                                   : localized("Four-finger double tap")
            let row = Controls.row(label,
                                   Controls.toggle(Prefs.gestureFingerCounts.contains(count)) { [weak self] on in
                                       self?.setGestureFinger(count, on)
                                   }, indented: true)
            dependent["gesture.\(count)"] = row
            return row
        }

        return Controls.section(localized("Trackpad"), symbol: "hand.tap.fill", tint: .systemPurple, [
            Controls.row(localized("Trackpad gesture opens the search"),
                         Controls.toggle(Prefs.gestureEnabled) { [weak self] on in
                             Prefs.gestureEnabled = on
                             Launcher.shared.applyGesture(userAsked: true)
                             self?.syncDependentRows()
                         })
        ] + fingerRows)
    }

    /// The one permission the switcher needs, on the page of the thing that
    /// needs it. The same row is on the Settings page with the others.
    private func permission() -> NSView {
        let status = Controls.label("")
        accessibilityStatus = status
        let allow = Controls.button("Allow…") { [weak self] in
            Launcher.shared.grantAccessibility()
            self?.syncAccessibility()
        }
        accessibilityButton = allow
        let section = Controls.section(localized("Permission"), symbol: "lock.shield.fill",
                                       tint: .systemGreen, [
            Controls.row(localized("Window control"), Controls.group([status, allow]),
                         detail: localized("Accessibility access, which the switcher needs to bring windows forward."))
        ])
        syncAccessibility()
        return section
    }

    // MARK: - Rows

    /// A key, and whether Roost holds it -- in words, not a coloured dot.
    private func keyRow(_ label: String, detail: String? = nil,
                        state: @escaping () -> Launcher.KeyState) -> NSView {
        let status = Controls.label("")
        let refresh = {
            let key = state()
            status.stringValue = key.isActive ? key.keys
                                              : localized("%0 is taken by another app", key.keys)
            status.textColor = key.isActive ? .secondaryLabelColor : .systemRed
        }
        keyRows.append(refresh)
        refresh()
        return Controls.row(label, status, detail: detail)
    }

    // MARK: - Behaviour

    private func syncAccessibility() {
        accessibilityStatus?.stringValue = GeneralPane.accessibilityState
        accessibilityButton?.isHidden = WindowControl.isTrusted
    }

    /// Turning every finger count off would leave the gesture listening for
    /// nothing, so the last one on refuses to go off.
    private func setGestureFinger(_ count: Int, _ on: Bool) {
        var counts = Prefs.gestureFingerCounts
        if on {
            counts.insert(count)
        } else {
            guard counts.count > 1 else {
                syncDependentRows()
                Alert.show("Keep at least one",
                           "Turn the trackpad gesture off instead if you do not want it.")
                return
            }
            counts.remove(count)
        }
        Prefs.gestureFingerCounts = counts
        Launcher.shared.applyGesture()
    }

    /// The finger counts only mean something while the gesture is on.
    private func syncDependentRows() {
        let gesture = Prefs.gestureEnabled
        for count in [3, 4] {
            let row = dependent["gesture.\(count)"]
            row?.isHidden = !gesture
            if let toggle = row?.subviews.compactMap({ $0 as? ActionSwitch }).first {
                toggle.state = Prefs.gestureFingerCounts.contains(count) ? .on : .off
            }
        }
    }
}
