import AppKit

/// The side of `FormerName` that touches the disk.
extension FormerName {

    /// Set on the launch that brought settings across, so `Startup` tells the
    /// user about the name rather than about an update -- `Notice` asks for
    /// permission once per launch, and the new identifier has never been
    /// granted it, so a second alert would be dropped.
    private(set) static var migratedThisLaunch = false

    /// Runs before anything reads a preference.
    static func migrate() {
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
}
