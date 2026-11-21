import Foundation

/// Roost's settings, typed.
///
/// Backed by `UserDefaults.standard` under exactly the keys Kit's `Store` used
/// — `dockIcon`, `temperature_units`, `CombinedModules` and the rest — so a
/// Mac that has been running Roost keeps every preference it already had. This
/// is a replacement, not a migration: nothing is copied, renamed or rewritten
/// on first launch, because there is nothing to move.
///
/// Written as one type with named properties rather than string lookups
/// scattered through the views. A pane asks for `Preferences.shared.dockIcon`;
/// if the key is ever wrong it is wrong in one place.
final class Preferences {

    static let shared = Preferences()

    private let defaults: UserDefaults
    /// Which persistent domain `defaults` writes to.
    ///
    /// Carried explicitly because export and reset work on a whole domain, and
    /// a domain is addressed by name rather than through the UserDefaults
    /// object. Taking the name from the bundle regardless of which store was
    /// injected meant export read a different domain than the one it was
    /// reading settings from -- fine for the app, wrong for anything else,
    /// and untestable.
    private let domain: String

    /// Posted after any change, so panes opened twice cannot disagree.
    static let didChange = Notification.Name("RoostPreferencesDidChange")

    init(defaults: UserDefaults = .standard, domain: String? = nil) {
        self.defaults = defaults
        self.domain = domain ?? Bundle.main.bundleIdentifier ?? "com.sagar.roost"
    }

    // MARK: - Reading and writing

    func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    func string(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    /// nil when nothing is stored, which is not the same as an empty list:
    /// the Dashboard tells "never customised" from "hid everything" by it.
    func strings(_ key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    func set(_ key: String, _ value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: Preferences.didChange, object: key)
    }

    func exists(_ key: String) -> Bool { defaults.object(forKey: key) != nil }

    /// Forgets everything Roost has stored.
    ///
    /// The whole persistent domain in one call. What this replaces walked
    /// `dictionaryRepresentation()` removing keys one at a time -- and that
    /// is the *merged* view, so it iterated every global preference on the
    /// machine to delete the handful that were ours. Same outcome, narrower
    /// blast radius, and it cannot touch another application's settings
    /// even by accident.
    ///
    /// Used by `--reset` and by the first launch after an upgrade from a
    /// version too old to have a version marker.
    func reset() {
        defaults.removePersistentDomain(forName: domain)
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }

    // MARK: - The settings the app shell owns

    var updateInterval: String {
        get { string("update-interval", default: "Once per day") }
        set { set("update-interval", newValue) }
    }

    var temperatureUnits: String {
        get { string("temperature_units", default: "system") }
        set { set("temperature_units", newValue) }
    }

    var dockIcon: Bool {
        get { bool("dockIcon", default: false) }
        set { set("dockIcon", newValue) }
    }

    var combinedModules: Bool {
        get { bool("CombinedModules", default: false) }
        set { set("CombinedModules", newValue) }
    }

    var combinedSpacing: String {
        get { string("CombinedModules_spacing", default: "none") }
        set { set("CombinedModules_spacing", newValue) }
    }

    var combinedSeparator: Bool {
        get { bool("CombinedModules_separator", default: false) }
        set { set("CombinedModules_separator", newValue) }
    }

    var combinedPopup: Bool {
        get { bool("CombinedModules_popup", default: true) }
        set { set("CombinedModules_popup", newValue) }
    }

    // MARK: - Export and import

    /// Everything Roost has stored, as a plist.
    ///
    /// The whole domain rather than a hand-kept list of keys: the old export
    /// enumerated what it knew about, so a module's settings were silently
    /// left out of the backup that was supposed to contain them.
    func exportAll() throws -> Data {
        let all = defaults.persistentDomain(forName: domain) ?? [:]
        return try PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
    }

    /// Replaces the stored settings with the contents of an export.
    ///
    /// Returns how many keys were written. Throws rather than failing quietly
    /// if the file is not a settings export at all.
    ///
    /// An export made by Perch, the app's old name, has the old bundle
    /// identifier inside its window-frame keys. Written as they were, they
    /// were keys nothing reads, so the import reported success and the windows
    /// still forgot where they were. They go through the same renaming as the
    /// first-launch migration.
    ///
    /// Replaces, as it says: everything but the bookkeeping is cleared first.
    /// It used to write the file's keys over what was there, so a module
    /// switched on since the backup -- a key the backup never had -- stayed
    /// on after "restoring" it. And it took any plist with a dictionary at
    /// the top, so another app's preferences or an Info.plist imported as
    /// "37 settings" and lived in Roost's domain from then on.
    @discardableResult
    func importAll(_ data: Data) throws -> Int {
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let values = parsed as? [String: Any], Self.isRoostExport(values.keys) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        for key in (defaults.persistentDomain(forName: domain) ?? [:]).keys
        where !Self.isBookkeeping(key) {
            defaults.removeObject(forKey: key)
        }
        var written = 0
        for (key, value) in values where !Self.isBookkeeping(key) {
            defaults.set(FormerName.Plan.renamedKeys(value, to: domain),
                         forKey: FormerName.Plan.renamed(key, to: domain))
            written += 1
        }
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
        return written
    }

    /// Keys that record this Mac's history with the app rather than a
    /// choice: neither taken from a backup nor cleared by one. A backup's
    /// `version` is the version that made it, and restoring an older one
    /// set the record back, so the next launch announced an update that had
    /// not happened; its `setupProcess` decides whether first-run shows.
    static func isBookkeeping(_ key: String) -> Bool {
        ["version", "setupProcess", "runAtLoginInitialized", "LaunchAtLoginNext",
         "update_last_check"].contains(key)
            || key.hasPrefix("support_")
    }

    /// Whether a plist's keys look like this app's. Any one is enough: a
    /// backup holds only what was ever changed, and a Perch backup can be a
    /// window frame and a switch.
    static func isRoostExport<Keys: Sequence>(_ keys: Keys) -> Bool where Keys.Element == String {
        let named: Set<String> = ["version", "setupProcess", "dockIcon", "temperature_units",
                                  "update-interval", "pause"]
        let prefixes = ["CPU_", "GPU_", "RAM_", "Disk_", "Sensors_", "Network_", "Clipboard_",
                        "Battery_", "CombinedModules", "Dashboard", "Launcher", "AICleaner_",
                        "NSWindow Frame com.sagar."]
        return keys.contains { key in
            named.contains(key) || key.hasSuffix("_state")
                || prefixes.contains { key.hasPrefix($0) }
        }
    }

    /// Forgets everything. The caller restarts the app.
    func resetAll() {
        defaults.removePersistentDomain(forName: domain)
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }
}

/// Sizes the settings window is laid out to.
///
/// Three numbers that were reached for through a framework-wide constants
/// table. They are the settings window's own, so they live beside it.
enum SettingsMetrics {
    static let width: CGFloat = 540
    static let height: CGFloat = 480
    static let margin: CGFloat = 10
    /// The height of a popup's title bar, which the settings window's
    /// minimum height is measured against.
    static let popupHeaderHeight: CGFloat = 42
}
