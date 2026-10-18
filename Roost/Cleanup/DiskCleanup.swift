import AppKit

/// Getting space back, without Roost being the one to delete anything.
///
/// The obvious feature here is a button that empties the Bin and clears some
/// caches. It is not built, and the reason is worth keeping: **the Bin cannot
/// be read without Full Disk Access.** `~/.Trash` is TCC-protected, so even
/// showing its size would mean asking a menu bar monitor for the broadest
/// file permission macOS has — and an app that asks for that to tidy up has
/// asked for everything, forever, to do something Finder already does with a
/// confirmation sheet.
///
/// The other half of the usual offering is worse than useless. Clearing
/// `~/Library/Caches` frees space that applications immediately rebuild,
/// slowly, while things misbehave in the meantime; deleting unused language
/// files breaks the localisation it took this app 263 keys to get right.
/// Neither is cleanup, and both are what "cleaner" apps sell.
///
/// So this points at the two places that genuinely do the work and needs no
/// permission to do it. macOS already knows what is reclaimable, which
/// snapshots it can thin and which downloads it can re-fetch; the useful act
/// is getting somebody there with the number that made them look.
enum DiskCleanup {

    /// macOS's own storage management: large files, old backups, what the
    /// system can purge. The thing that actually frees space.
    static func openStorageSettings() {
        // Both identifiers land on the same pane; the second is the newer
        // spelling and the first is kept because it still answers and costs
        // nothing to try first.
        for identifier in ["x-apple.systempreferences:com.apple.settings.Storage",
                           "x-apple.systempreferences:com.apple.Storage-Settings.extension"] {
            if let url = URL(string: identifier),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    /// Opens the Bin in Finder.
    ///
    /// Finder can read it and Roost cannot, which is the whole design: the
    /// emptying happens in the app that already has permission and already
    /// asks before it does it.
    static func openBin() {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return }
        NSWorkspace.shared.open(trash)
    }

    /// Whether a volume is worth suggesting a tidy-up for.
    ///
    /// Only the startup volume, and only when it is genuinely tight. An
    /// external drive at 92% is usually an archive disk doing its job, and a
    /// prompt about it is noise; the boot volume at 92% is a machine about to
    /// start misbehaving.
    static func isWorthSuggesting(path: String, percentUsed: Double) -> Bool {
        path == "/" && percentUsed >= 0.90
    }
}
