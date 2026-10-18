import AppKit

/// The side of `FormerName` that touches the disk and the process.
extension FormerName {

    /// Set on the launch that brought settings across, so `Startup` tells the
    /// user about the name rather than about an update -- `Notice` asks for
    /// permission once per launch, and the new identifier has never been
    /// granted it, so a second alert would be dropped.
    private(set) static var migratedThisLaunch = false

    /// Runs before anything reads a preference. Returns false when this copy
    /// has moved itself and relaunched, and must not carry on starting.
    static func migrate() -> Bool {
        if relaunchUnderNewName() { return false }

        let defaults = UserDefaults.standard
        let newIdentifier = Bundle.main.bundleIdentifier ?? "com.sagar.roost"
        let current = defaults.persistentDomain(forName: newIdentifier) ?? [:]
        let old = defaults.persistentDomain(forName: oldIdentifier)
        if let old, let merged = Plan.defaults(old: old, current: current,
                                               newIdentifier: newIdentifier) {
            defaults.setPersistentDomain(merged, forName: newIdentifier)
            var marked = old
            marked[markerKey] = true
            defaults.setPersistentDomain(marked, forName: oldIdentifier)
            migratedThisLaunch = true
            Log.info("carried settings across from \(oldIdentifier)")
        }
        // Not tied to the settings: someone who deleted Perch's preferences
        // still has a launcher list and a clipboard history to keep.
        moveSupportFolder()
        return true
    }

    /// Moved rather than copied: two copies of the clipboard history is one
    /// the user cannot clear from the app.
    private static func moveSupportFolder() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let old = support.appendingPathComponent(oldSupportFolder, isDirectory: true)
        let new = Config.directory
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            NSLog("Roost: could not move \(old.path) to \(new.path): \(error)")
        }
    }

    /// A running bundle can be moved -- the process holds its files open, not
    /// their path -- but it cannot relaunch itself from the new path while it
    /// is still the copy registered for the hotkeys. So a detached shell waits
    /// for this process to go, as the updater's install script does, and
    /// opens the moved bundle.
    private static func relaunchUnderNewName() -> Bool {
        let bundle = Bundle.main.bundleURL
        let fm = FileManager.default
        guard let target = Plan.renamedBundle(bundle, roostExists: { fm.fileExists(atPath: $0.path) })
        else { return false }
        do {
            try fm.moveItem(at: bundle, to: target)
        } catch {
            // /Applications not writable by this user. Running as Perch.app is
            // untidy but works, which beats refusing to start.
            NSLog("Roost: could not rename \(bundle.path): \(error)")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
                             "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                             target.path]
        do {
            try process.run()
        } catch {
            NSLog("Roost: could not relaunch \(target.path): \(error)")
            return false
        }
        return true
    }
}
