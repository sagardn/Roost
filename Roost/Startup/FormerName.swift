import Foundation

/// Carries a Mac across from the app's old name, Perch, once.
///
/// The rename changed two things a running copy keeps state under, and
/// each would have looked to the user like Roost had forgotten them:
///
/// - **The bundle identifier**, `com.sagar.perch` to `com.sagar.roost`. Every
///   preference lives in a domain named after it, so the new identifier starts
///   with none -- and `Startup` reads "no version recorded" as a first run and
///   resets, so nothing would have been recovered later either.
/// - **`~/Library/Application Support/Perch`**, which holds `apps.json` and the
///   clipboard history.
///
/// Installing Roost does not replace Perch: Perch's updater asks for a
/// `Perch.dmg` that no release publishes, so nothing ever writes Roost over
/// it. The install scripts remove `Perch.app`; this brings across what it
/// left in the user's Library.
///
/// The decisions are pure and live in `Plan`, so `Tools/formername-test.swift`
/// can check them; `migrate()`, in `FormerNameMigration.swift`, is the glue.
enum FormerName {

    static let oldIdentifier = "com.sagar.perch"
    static let oldSupportFolder = "Perch"

    /// Written into the *old* domain, not the new one. "Reset settings"
    /// removes the new domain wholesale, and a marker kept there went with it,
    /// so the next launch brought every Perch setting back -- undoing the
    /// reset. The old domain is otherwise left alone, so an older copy still
    /// on the disk keeps working.
    static let markerKey = "migratedToRoost"

    enum Plan {

        /// `NSWindow Frame com.sagar.perch.Settings.WindowFrame` and the
        /// toolbar configuration are keyed by identifiers this app builds from
        /// its own bundle identifier, so the key has to follow it or the
        /// windows forget where they were.
        static func renamed(_ key: String, to newIdentifier: String) -> String {
            key.replacingOccurrences(of: FormerName.oldIdentifier, with: newIdentifier)
        }

        /// Recursive because the launcher's last-used map is a dictionary keyed
        /// by bundle identifier, and the app's own entry is in it.
        static func renamedKeys(_ value: Any, to newIdentifier: String) -> Any {
            guard let dictionary = value as? [String: Any] else { return value }
            var out: [String: Any] = [:]
            for (key, inner) in dictionary {
                out[renamed(key, to: newIdentifier)] = renamedKeys(inner, to: newIdentifier)
            }
            return out
        }

        /// The domain to write, or nil when there is nothing to carry across.
        ///
        /// A key already present in the new domain wins: it was set by Roost,
        /// which is the more recent of the two.
        static func defaults(old: [String: Any]?, current: [String: Any],
                             newIdentifier: String) -> [String: Any]? {
            guard let old, !old.isEmpty, old[FormerName.markerKey] == nil else { return nil }
            var merged = current
            for (key, value) in old {
                let key = renamed(key, to: newIdentifier)
                if merged[key] == nil { merged[key] = renamedKeys(value, to: newIdentifier) }
            }
            return merged
        }
    }
}
