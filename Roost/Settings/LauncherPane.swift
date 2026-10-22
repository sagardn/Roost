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
/// What is new is the Shortcuts section. A global key belongs to whichever
/// process registers it first, and until now the only report that another
/// app had ⌃Space was a HUD at launch that was gone in four seconds. The
/// section reads what `Launcher` actually holds, and says so.
final class LauncherPane: NSStackView {

    private var dependent: [String: NSView] = [:]
    private var keyRows: [() -> Void] = []
    private var accessibilityStatus: NSTextField?
    private var accessibilityButton: NSButton?
    private var permissionSection: NSView?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = RoostMetrics.sectionSpacing
        edgeInsets = NSEdgeInsets(top: RoostMetrics.pageTop, left: RoostMetrics.pageInset,
                                  bottom: RoostMetrics.pageInset, right: RoostMetrics.pageInset)

        // Ordered as somebody learns the thing: what it is and how to use
        // it, then the ways to open it, then how it behaves once open. The
        // page used to start on a list of shortcuts and put a section named
        // after the feature second, so nothing on it said what the feature
        // was for.
        for section in [howItWorks(), permission(), keyboard(), snapping(), gesture(), searchWindow(), clicking()] {
            addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: widthAnchor,
                                           constant: -RoostMetrics.pageInset * 2).isActive = true
        }
        syncDependentRows()
        placePermission()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The two things that change behind the page's back: a key another app
    /// let go of, and the Accessibility grant.
    func viewWillAppear() {
        keyRows.forEach { $0() }
        syncAccessibility()
    }

    // MARK: - Sections

    /// The three steps of using it, and a button that does the first one.
    /// A switcher is learned by trying it, and until now the only way to try
    /// it from here was to know the key already.
    private func howItWorks() -> NSView {
        let steps = StepStrip([
            (localized("Press %0", Launcher.shared.searchKey.keys),
             localized("From any app. Or double-tap the trackpad, if that is on below.")),
            (localized("Type a few letters"),
             localized("Part of an app's name is enough. A dot means it is running.")),
            (localized("Press Return"),
             localized("Roost brings the app forward, or opens it if it is not running."))
        ], tint: .systemPurple)
        let tryIt = Controls.row(localized("Try it now"),
                                 Controls.button("Open the search") { Launcher.shared.showSearch() },
                                 detail: localized("⌃Tab and the shortcuts below switch apps without opening it at all."))
        return Controls.section(localized("How it works"), symbol: "magnifyingglass",
                                tint: .systemPurple, [Controls.row(steps), tryIt])
    }

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

        let apps = Controls.row(localized("My Apps"),
                                Controls.button(localized("Edit apps…")) { Launcher.shared.editApps() },
                                detail: localized("Reorder them, and give any of them a ⌃ shortcut that switches straight to it."))

        return Controls.section(localized("Shortcuts"), symbol: "keyboard.fill", tint: .systemPurple,
                                footer: localized("A key another app registered first stays that app's. Roost does not take it over; it says so here instead."),
                                [search, minimise, cycle, apps])
    }

    /// Thirteen system-wide keys, which were taken at launch and listed
    /// nowhere but one line of the welcome tour. Listed, so a person knows
    /// what ⌃⌥← is doing to their window, and why another app's ⌃⌥C
    /// might not work.
    private func snapping() -> NSView {
        let rows = WindowSnapper.bindings.map { binding -> NSView in
            let keys = Controls.label(binding.label)
            keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            return Controls.row(Self.title(of: binding.action), keys)
        }
        return Controls.section(localized("Window snapping"), symbol: "rectangle.split.2x1", tint: .systemPurple,
                                footer: localized("Works on the window in front. Pressing a half again makes it two thirds, then one third."),
                                rows)
    }

    private static func title(of action: Snap.Action) -> String {
        switch action {
        case .leftHalf:        return localized("Left half")
        case .rightHalf:       return localized("Right half")
        case .topHalf:         return localized("Top half")
        case .bottomHalf:      return localized("Bottom half")
        case .topLeft:         return localized("Top-left quarter")
        case .topRight:        return localized("Top-right quarter")
        case .bottomLeft:      return localized("Bottom-left quarter")
        case .bottomRight:     return localized("Bottom-right quarter")
        case .maximize:        return localized("Fill the screen")
        case .center:          return localized("Centre")
        case .restore:         return localized("Put it back where it was")
        case .previousDisplay: return localized("Move to the previous display")
        case .nextDisplay:     return localized("Move to the next display")
        }
    }

    private func searchWindow() -> NSView {
        Controls.section(localized("The search window"), symbol: "macwindow", tint: .systemPurple, [
            Controls.row(localized("Open where the pointer is"),
                         Controls.toggle(Prefs.openAtPointer) { Prefs.openAtPointer = $0 }),
            Controls.row(localized("Close when it loses focus"),
                         Controls.toggle(Prefs.hideOnOutsideClick) { Prefs.hideOnOutsideClick = $0 })
        ])
    }

    /// Apart from the window's own settings: these change what a click on an
    /// app does everywhere, the Dock included, and under the window's
    /// heading they read as though they were about the window.
    private func clicking() -> NSView {
        Controls.section(localized("Clicking an app"), symbol: "cursorarrow.click.2", tint: .systemPurple, [
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
        permissionSection = section
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
        placePermission()
    }

    /// Second on the page while it is missing, last once it is granted.
    /// Without it the switcher cannot bring a window forward, and a section
    /// at the bottom of a long page is where that went unnoticed -- the keys
    /// worked, the search opened, and picking an app did nothing.
    private func placePermission() {
        guard let section = permissionSection, section.superview === self else { return }
        let wanted = WindowControl.isTrusted ? arrangedSubviews.count - 1 : 1
        guard arrangedSubviews.firstIndex(of: section) != wanted else { return }
        removeArrangedSubview(section)
        insertArrangedSubview(section, at: wanted)
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
