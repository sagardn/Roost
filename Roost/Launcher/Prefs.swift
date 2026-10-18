import Foundation

/// Launcher settings that do not belong in the app list file.
///
/// Deliberately UserDefaults rather than Kit's Store: these belong to the
/// launcher half of the app and outlive any module being enabled.
enum Prefs {
    private static let cycleKey = "cycleHotkeyEnabled"

    /// Ctrl+Tab cycles recent apps. On by default, but it does take Ctrl+Tab
    /// from browsers and terminals, so it is switchable.
    static var cycleHotkeyEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: cycleKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: cycleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: cycleKey) }
    }

    private static let windowSnappingKey = "windowSnapping"

    /// ⌃⌥ + arrows (and the rest of WindowSnapper's keys) move the frontmost
    /// window. On by default; off gives the keys back to whatever else wants
    /// them -- Rectangle, most often.
    static var windowSnapping: Bool {
        get {
            if UserDefaults.standard.object(forKey: windowSnappingKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: windowSnappingKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: windowSnappingKey) }
    }

    private static let openAtPointerKey = "openAtPointer"
    private static let gestureKey = "gestureEnabled"
    private static let hideOnOutsideClickKey = "hideOnOutsideClick"
    private static let gestureFingersKey = "gestureFingers"
    private static let gestureTapsKey = "gestureTaps"
    private static let gestureFingerCountsKey = "gestureFingerCounts"

    /// Where the search panel appears.  Defaults to the pointer, which is how
    /// the menu behaved before the panel existed.
    private static let clickMinimizesKey = "clickMinimizes"

    /// Whether clicking the app you are already in minimises it.
    ///
    /// Off turns the launcher back into a plain launcher: a click only ever
    /// brings an app forward, which is what macOS does and what somebody
    /// coming from it may want back. It governs the panel and the per-app
    /// hotkeys together, because they are the same click by another route.
    static var clickMinimizes: Bool {
        get {
            if UserDefaults.standard.object(forKey: clickMinimizesKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: clickMinimizesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: clickMinimizesKey) }
    }

    private static let dockClickKey = "dockClickPutsAway"

    /// Click an app in the Dock to bring it up, click it again to put it
    /// away. On by default: it only adds behaviour to a click that macOS
    /// currently answers by doing nothing, so nothing a person already
    /// relies on changes.
    static var dockClickPutsAway: Bool {
        get {
            if UserDefaults.standard.object(forKey: dockClickKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: dockClickKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: dockClickKey) }
    }

    static var openAtPointer: Bool {
        get {
            if UserDefaults.standard.object(forKey: openAtPointerKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: openAtPointerKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: openAtPointerKey) }
    }

    /// Trackpad gesture opens the search. On by default.
    static var gestureEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: gestureKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: gestureKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: gestureKey) }
    }

    /// Whether the search panel closes when it loses focus. On by default,
    /// which is how Spotlight behaves. Turn it off to keep the panel up while
    /// you click around elsewhere; Escape or Ctrl+Space still closes it.
    static var hideOnOutsideClick: Bool {
        get {
            if UserDefaults.standard.object(forKey: hideOnOutsideClickKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: hideOnOutsideClickKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: hideOnOutsideClickKey) }
    }

    /// Which finger counts the trackpad gesture answers to, and how many taps.
    ///
    /// Three fingers by default. Two is deliberately not offered: macOS makes
    /// a two-finger tap a secondary click and a two-finger double tap Smart
    /// Zoom, and this layer can only observe touches -- it cannot swallow
    /// them -- so every search also fired a right-click and a zoom. Three is
    /// Look Up, which is far less disruptive, and four is the one combination
    /// nothing stock claims.
    static var gestureFingerCounts: Set<Int> {
        get {
            migrateGestureFingers()
            guard let stored = UserDefaults.standard.array(forKey: gestureFingerCountsKey) as? [Int],
                  !stored.isEmpty else { return [3] }
            let valid = Set(stored.filter { Self.validFingerCounts.contains($0) })
            // A stored [2] from before two fingers was dropped would leave the
            // gesture listening for nothing.
            return valid.isEmpty ? [3] : valid
        }
        set {
            let clean = newValue.filter { Self.validFingerCounts.contains($0) }.sorted()
            UserDefaults.standard.set(clean, forKey: gestureFingerCountsKey)
        }
    }

    /// Carries forward the single `gestureFingers` number this used to store,
    /// so anyone who had picked four fingers keeps four fingers instead of
    /// silently getting the new default.
    private static func migrateGestureFingers() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gestureFingerCountsKey) == nil else { return }
        let old = defaults.integer(forKey: gestureFingersKey)
        let carried = validFingerCounts.contains(old) ? [old] : [3]
        defaults.set(carried, forKey: gestureFingerCountsKey)
    }

    /// Three and four only. See the note on `gestureFingerCounts`.
    static let validFingerCounts: Set<Int> = [3, 4]

    static var gestureTaps: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: gestureTapsKey)
            return value == 0 ? 2 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: gestureTapsKey) }
    }
}

/// The readings that can be shown in the menu bar, in the order they are
/// drawn. Raw values are what lands in UserDefaults, so they are stable.
