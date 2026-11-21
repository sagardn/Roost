import AppKit

/// The menu a right-click gives, on a menu bar reading or inside a popup.
///
/// Roost had no right-click anywhere: the only way out of the app was a
/// power button in the corner of the Settings window, which somebody has to
/// find before they can use it. Every other menu bar app answers a
/// right-click with Quit, and that is where people look first.
///
/// Deliberately three items. A menu bar app's context menu is not a place to
/// put features -- it is the place somebody goes when they want the window
/// they cannot find, or the app gone.
enum AppMenu {

    /// `module` is the reading that was right-clicked: the page Settings
    /// opens, and the one "Turn off" takes out of the menu bar.
    static func make(for module: String? = nil) -> NSMenu {
        let menu = NSMenu()

        // First, because it is the reason somebody right-clicked this
        // particular reading rather than any other. Quitting the whole app
        // to be rid of one figure is not what they meant.
        if let module, ModuleRegistry.shared.named(module) != nil {
            let off = NSMenuItem(title: localized("Turn off %0", localized(module)),
                                 action: #selector(Target.turnOff(_:)), keyEquivalent: "")
            off.target = target
            off.representedObject = module
            menu.addItem(off)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: localized("Settings") + "…",
                                  action: #selector(Target.openSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = target
        settings.representedObject = module
        menu.addItem(settings)

        let paused = Preferences.shared.bool("pause", default: false)
        let pause = NSMenuItem(title: paused ? localized("Resume") : localized("Pause"),
                               action: #selector(Target.togglePause),
                               keyEquivalent: "")
        pause.target = target
        menu.addItem(pause)

        // Only while it is on. Keep awake is started from the search panel
        // and nothing else on screen says it is holding the Mac awake, so
        // the menu somebody opens to get rid of something is where it can
        // be seen and stopped. Off, it is not a row here: this menu is not
        // a place to put features.
        if KeepAwake.shared.isOn {
            // With when it ends, for a timed one: the menu is where somebody
            // looks to find out why the Mac has not slept.
            let title = KeepAwake.shared.endsAt.map {
                localized("Allow Sleep Again (awake until %0)", KeepAwake.time($0))
            } ?? localized("Allow Sleep Again")
            let awake = NSMenuItem(title: title,
                                   action: #selector(Target.allowSleep), keyEquivalent: "")
            awake.target = target
            menu.addItem(awake)
        }
        // Running timers, the same way: started from the search panel, seen
        // and stopped here.
        for timer in RoostTimers.shared.running {
            let stop = NSMenuItem(title: localized("Stop Timer (%0)", RoostTimers.describe(timer)),
                                  action: #selector(Target.stopTimer(_:)), keyEquivalent: "")
            stop.target = target
            stop.representedObject = timer.id
            menu.addItem(stop)
        }

        menu.addItem(.separator())

        // No confirmation. Quitting a menu bar app loses nothing -- every
        // setting is already written -- and an "are you sure" on the one
        // thing somebody opened the menu for is noise.
        let quit = NSMenuItem(title: localized("Quit Roost"),
                              action: #selector(Target.quit), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        return menu
    }

    /// Menu items need a target that outlives the menu. A menu built on the
    /// stack and shown with `popUp` is gone by the time the action fires, so
    /// the target cannot be the thing that built it.
    private static let target = Target()

    private final class Target: NSObject {
        @objc func openSettings(_ sender: NSMenuItem) {
            NotificationCenter.default.post(
                name: .toggleSettings, object: nil,
                userInfo: ["module": (sender.representedObject as? String) ?? "Dashboard"])
        }

        /// Takes one module out of the menu bar and leaves the rest alone.
        ///
        /// The same path the switch in Settings uses, including `stop()` for
        /// `willStop()`, so a module turned off here cannot leave a
        /// threshold alert posted about a reading that is gone. The
        /// notification is what keeps the switch in Settings in step if the
        /// window is open.
        @objc func turnOff(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String,
                  let module = ModuleRegistry.shared.named(name) else { return }
            module.isEnabled = false
            module.stop()
            NotificationCenter.default.post(name: .toggleModule, object: nil,
                                            userInfo: ["module": name, "state": false])
        }

        @objc func togglePause() {
            let paused = Preferences.shared.bool("pause", default: false)
            Preferences.shared.set("pause", !paused)
            NotificationCenter.default.post(name: .pause, object: nil)
        }

        @objc func allowSleep() {
            KeepAwake.shared.turnOff()
            Notify.show(localized("The Mac can sleep again"), symbol: "moon.zzz")
        }

        @objc func stopTimer(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            RoostTimers.shared.cancel(id)
        }

        @objc func quit() { NSApp.terminate(nil) }
    }
}
