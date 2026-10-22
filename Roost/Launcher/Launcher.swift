import AppKit

/// The app-switcher half of Roost: the Ctrl+Space search panel, the per-app
/// hotkeys, the minimize/restore key and the trackpad gesture.
///
/// Kept as one controller rather than folded into AppDelegate so the two
/// halves of the app stay separable -- the monitoring side has its own module
/// system and knows nothing about this, and this knows nothing about modules.
final class Launcher {

    static let shared = Launcher()

    private var entries: [AppEntry] = []
    private var searchPanel: SearchPanel?
    private var appsWindow: AppsWindow?

    private var searchHotkey: Hotkey?
    private var minimizeHotkey: Hotkey?
    private var cycleHotkey: Hotkey?
    /// Ctrl+<digit> straight to one app. Held so they stay registered.
    private var appHotkeys: [Hotkey] = []

    /// What the minimize hotkey put away, so the same key can bring it back.
    private var stashed: [String] = []

    private init() {}

    func start() {
        entries = Config.load()
        Recents.shared.start()
        DockWatcher.shared.start()

        searchPanel = SearchPanel(source: { [weak self] in self?.entries ?? [] },
                                  onPick: { entry, active in WindowControl.toggle(entry, activeApp: active) },
                                  onSetListed: { [weak self] changed, listed in
                                      self?.setListed(changed, listed)
                                  },
                                  onEditApps: { [weak self] in self?.editApps() },
                                  isMarked: { [weak self] bundleID in
                                      self?.entries.first { $0.bundleID == bundleID }?.marked ?? false
                                  },
                                  onSetMarked: { [weak self] entry, marked in
                                      self?.setMarked(entry, marked)
                                  })

        var taken: [String] = []

        searchHotkey = Hotkey(keyCode: Hotkey.Key.space, modifiers: .control) { [weak self] in
            self?.searchPanel?.toggle()
        }
        if searchHotkey == nil { taken.append("⌃Space") }
        // The search panel's rows show each app's state. Keeping that cache
        // correct is now the business of the notifications macOS already
        // sends, rather than of a timer that swept every app on a clock.
        WindowControl.observeAppChanges()
        // Ctrl+Tab walks back through recently used apps, one press per step.
        // Note this takes Ctrl+Tab away from every app that uses it for tab
        // switching -- Chrome, Safari, terminals -- because a global hotkey
        // consumes the key. Turn it off in the menu if that bites.
        if Prefs.cycleHotkeyEnabled {
            let cycle: () -> Void = { [weak self] in
                Recents.shared.cycleToNext(among: self?.markedBundleIDs)
            }
            cycleHotkey = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .control, action: cycle)

            // ⌃Tab is popular: browsers, terminals and window managers all
            // want it, and RegisterEventHotKey hands it to whoever asked
            // first. When that happens the key used to do nothing at all, with
            // the reason buried in the system log. Fall back to ⌥Tab and say
            // so, rather than shipping a feature that silently is not there.
            if cycleHotkey == nil {
                cycleHotkey = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .option, action: cycle)
                if cycleHotkey != nil {
                    self.cycleUsesOption = true
                } else {
                    taken.append("⌃Tab")
                }
            }
        }

        minimizeHotkey = Hotkey(keyCode: Hotkey.Key.grave, modifiers: .control) { [weak self] in
            self?.toggleFrontmost()
        }
        if minimizeHotkey == nil { taken.append("⌃`") }
        registerAppHotkeys()
        if Prefs.windowSnapping { WindowSnapper.shared.startAndReport() }

        Gesture.shared.onTap = { [weak self] in self?.searchPanel?.toggle() }
        if Prefs.gestureEnabled {
            Gesture.shared.start(fingers: Prefs.gestureFingerCounts, taps: Prefs.gestureTaps)
        }

        // A collision is often momentary rather than permanent: an update
        // relaunches the app, and for a second the copy being replaced still
        // owns these keys. Reporting straight away would tell the user their
        // shortcuts are taken when they are about to be free, so try the
        // failures once more before saying anything.
        if taken.isEmpty && !self.cycleUsesOption {
            self.reportHotkeys(taken: [])
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.retryHotkeys(taken: taken)
            }
        }

        // Raising a window needs no permission; minimizing one does.
        //
        // Nothing is asked for here. This used to call requestAccessibility()
        // on every launch, which is the macOS dialog itself -- so a Mac where
        // the grant was missing, or had been invalidated by an update, showed
        // "Roost would like to control this computer" at every single login
        // with no way to make it stop. The permission is now asked for at the
        // moment it is actually needed, once, and the answer is remembered.
        if !WindowControl.isTrusted {
            NSLog("Roost: Accessibility not granted; window control is unavailable until it is")
        }
    }

    // MARK: - Accessibility

    /// True when the permission was granted once and is not in force now.
    var accessibilityWasRevoked: Bool { WindowControl.wasRevoked }

    @discardableResult
    func ensureAccessibility(for what: String) -> Bool {
        WindowControl.ensureTrusted(for: what)
    }

    /// The Settings button.
    func grantAccessibility() { WindowControl.grantFromSettings() }

    /// True when ⌃Tab was already taken and the cycle moved to ⌥Tab.
    private var cycleUsesOption = false

    /// Second attempt at whatever would not register, three seconds later.
    private func retryHotkeys(taken: [String]) {
        var stillTaken: [String] = []

        for name in taken {
            switch name {
            case "⌃Space":
                searchHotkey = Hotkey(keyCode: Hotkey.Key.space, modifiers: .control) { [weak self] in
                    self?.searchPanel?.toggle()
                }
                if searchHotkey == nil { stillTaken.append(name) }
            case "⌃Tab":
                cycleHotkey = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .control) { [weak self] in
                    Recents.shared.cycleToNext(among: self?.markedBundleIDs)
                }
                if cycleHotkey == nil { stillTaken.append(name) }
            case "⌃`":
                minimizeHotkey = Hotkey(keyCode: Hotkey.Key.grave, modifiers: .control) { [weak self] in
                    self?.toggleFrontmost()
                }
                if minimizeHotkey == nil { stillTaken.append(name) }
            default:
                stillTaken.append(name)
            }
        }

        // The fallback to ⌥Tab was taken under the same momentary collision,
        // so give ⌃Tab another chance before settling for it.
        if self.cycleUsesOption,
           let reclaimed = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .control, action: { [weak self] in
               Recents.shared.cycleToNext(among: self?.markedBundleIDs)
           }) {
            self.cycleHotkey = reclaimed
            self.cycleUsesOption = false
        }

        // Per-app keys share the same race, and there is no harm in asking again.
        self.registerAppHotkeys()

        self.reportHotkeys(taken: stillTaken)
    }

    /// Say which hotkeys another app already owns.
    ///
    /// A global hotkey belongs to whichever process registered it first, and
    /// nothing tells the loser. Before this, a Mac where something else held
    /// ⌃Space or ⌃Tab simply had a Roost that ignored those keys, which reads
    /// as a broken app rather than as a collision.
    private func reportHotkeys(taken: [String]) {
        if cycleUsesOption {
            NSLog("Roost: ⌃Tab was already registered by another app; using ⌥Tab for the app cycle")
            Notify.show("⌃Tab was taken — using ⌥Tab to cycle apps",
                        symbol: "keyboard", for: 4)
        }

        guard !taken.isEmpty else { return }
        let list = taken.joined(separator: ", ")
        NSLog("Roost: these hotkeys are owned by another app and will not fire: \(list)")
        Notify.show("\(list) \(taken.count == 1 ? "is" : "are") taken by another app",
                    symbol: "keyboard", for: 4)
    }

    /// The apps marked for Ctrl+Tab, or nil when none are.
    ///
    /// Marking is the whole switch: mark two or three apps and Ctrl+Tab walks
    /// only those, which is the point -- a cycle through everything recent is
    /// what Cmd-Tab already does. Mark nothing and it falls back to recents,
    /// so the key never does nothing.
    private var markedBundleIDs: Set<String>? {
        let marked = Set(entries.filter { $0.marked }.map { $0.bundleID })
        return marked.isEmpty ? nil : marked
    }

    /// Flip whether an app is in the Ctrl+Tab cycle.
    private func setMarked(_ entry: AppEntry, _ marked: Bool) {
        guard let index = entries.firstIndex(where: { $0.bundleID == entry.bundleID }) else {
            // Not in the list yet: marking implies adding it, otherwise the
            // mark would have nowhere to live.
            var added = entry
            added.marked = marked
            entries.append(added)
            Config.save(entries)
            Notify.show(marked ? "Added and marked \(entry.name)" : "Added \(entry.name)")
            return
        }
        entries[index].marked = marked
        Config.save(entries)
        Notify.show(marked ? "\(entry.name) joins ⌃Tab" : "\(entry.name) left ⌃Tab",
                    symbol: marked ? "arrow.left.arrow.right" : "minus.circle")
    }

    // MARK: - What the keys are doing

    /// A global key and whether Roost holds it.
    ///
    /// For the settings page, which used to have no way to say that a key
    /// was taken: the HUD at launch was the only report, gone in four
    /// seconds. Read-only -- registration, the ⌥Tab fallback and the retry
    /// after launch are `start()`'s, and none of them change here.
    struct KeyState {
        let keys: String
        let isActive: Bool
    }

    var searchKey: KeyState { KeyState(keys: "⌃Space", isActive: searchHotkey != nil) }
    var minimizeKey: KeyState { KeyState(keys: "⌃`", isActive: minimizeHotkey != nil) }
    /// nil while the cycle is switched off, since then no key is wanted.
    var cycleKey: KeyState? {
        guard Prefs.cycleHotkeyEnabled else { return nil }
        return KeyState(keys: cycleUsesOption ? "⌥Tab" : "⌃Tab", isActive: cycleHotkey != nil)
    }
    var cycleFellBack: Bool { cycleUsesOption }

    func showSearch() {
        searchPanel?.show()
    }

    func toggleSearch() {
        searchPanel?.toggle()
    }

    // MARK: - The app list

    /// One Ctrl+<key> per app that asked for one in the config.
    private func registerAppHotkeys() {
        appHotkeys.removeAll()
        for entry in entries {
            guard let shortcut = entry.shortcut,
                  let code = Hotkey.Key.code(for: shortcut) else { continue }
            if let hotkey = Hotkey(keyCode: code, modifiers: .control, action: {
                WindowControl.toggle(entry)
            }) {
                appHotkeys.append(hotkey)
            }
        }
    }

    /// Add or drop apps from the list, saving and re-registering the hotkeys
    /// so a removed app stops answering its Ctrl+digit. Takes a list because
    /// the file picker allows several at once, and six HUDs is not a report.
    private func setListed(_ changed: [AppEntry], _ listed: Bool) {
        var touched: [String] = []
        for entry in changed {
            let known = entries.contains { $0.bundleID == entry.bundleID }
            if listed {
                guard !known else { continue }
                entries.append(entry)
            } else {
                guard known else { continue }
                entries.removeAll { $0.bundleID == entry.bundleID }
            }
            touched.append(entry.name)
        }
        guard !touched.isEmpty else { return }

        Config.save(entries)
        registerAppHotkeys()
        let what = touched.count == 1 ? touched[0] : "\(touched.count) apps"
        Notify.show(listed ? "Added \(what)" : "Removed \(what)",
                    symbol: listed ? "plus.circle.fill" : "minus.circle.fill")
    }

    func editApps() {
        let window = AppsWindow(entries: entries) { [weak self] updated in
            guard let self else { return }
            self.entries = updated
            self.registerAppHotkeys()
        }
        appsWindow = window
        window.present()
    }

    func reload() {
        entries = Config.load()
        registerAppHotkeys()
        Notify.show(localized("Your app list was updated (%0 apps)", String(entries.count)))
    }

    // MARK: - Minimize / restore

    /// One key for both directions: after minimizing, the app is no longer
    /// frontmost, so pressing it again can only mean "bring back what I just
    /// put away".
    private func toggleFrontmost() {
        guard ensureAccessibility(for: localized("Minimising a window")) else { return }
        if let last = stashed.popLast() {
            if !WindowControl.restore(last) { Notify.show("Nothing to restore", symbol: "arrow.uturn.backward") }
            return
        }
        if let bundleID = WindowControl.minimizeFrontmost() {
            stashed.append(bundleID)
        }
    }

    // MARK: - Gesture

    /// Re-reads the gesture settings and starts or stops the listener, so a
    /// switch in Settings takes effect now rather than at the next launch.
    ///
    /// Nothing here asks for a permission: reading finger counts out of
    /// MultitouchSupport needs none (see Gesture.hasInputMonitoring). If the
    /// framework will not start at all -- a Mac with no trackpad, or a macOS
    /// that has moved the symbols -- the setting goes back off rather than
    /// sitting there claiming to be on.
    func applyGesture(userAsked: Bool = false) {
        guard Prefs.gestureEnabled else {
            Gesture.shared.stop()
            return
        }
        if !Gesture.shared.start(fingers: Prefs.gestureFingerCounts, taps: Prefs.gestureTaps) {
            Prefs.gestureEnabled = false
            if userAsked {
                Notify.show("Could not read the trackpad", symbol: "hand.raised.fill", for: 4)
            }
        }
    }

    /// Registers or releases ⌃Tab after the setting changes, so the switch in
    /// Settings takes effect now rather than at the next launch.
    func applyCycleHotkey() {
        guard Prefs.cycleHotkeyEnabled else {
            cycleHotkey = nil
            cycleUsesOption = false
            return
        }
        // Release first, always. Returning early when a key is already held
        // meant that switching the setting off and on again while the ⌥Tab
        // fallback was in use kept ⌥Tab for ever, even once whatever had taken
        // ⌃Tab was long gone.
        cycleHotkey = nil
        cycleUsesOption = false
        let cycle: () -> Void = { [weak self] in
            Recents.shared.cycleToNext(among: self?.markedBundleIDs)
        }
        cycleHotkey = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .control, action: cycle)
        if cycleHotkey == nil {
            cycleHotkey = Hotkey(keyCode: Hotkey.Key.tab, modifiers: .option, action: cycle)
            cycleUsesOption = cycleHotkey != nil
            reportHotkeys(taken: cycleHotkey == nil ? ["⌃Tab"] : [])
        }
    }

}
