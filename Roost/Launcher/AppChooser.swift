import AppKit
import UniformTypeIdentifiers

/// Adding an app that is neither running nor already in the list.
///
/// Everything else in Roost works from what is running or what apps.json
/// already names, which leaves installed-but-never-opened apps unreachable --
/// you cannot search for GIMP to add it if GIMP has never been launched. A
/// file picker is the shortest way out, and unlike enumerating /Applications
/// it also reaches apps kept somewhere else.
enum AppChooser {

    /// Name and identifier read from the bundle itself, so an app someone has
    /// renamed in Finder still lands under the identifier the hotkeys and the
    /// state lookups need.
    static func entry(for url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }

        let info = bundle.infoDictionary
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(name: name, bundleID: bundleID)
    }

    /// Opens the picker at /Applications. Several at once is allowed, since
    /// filling the list after a fresh install is the usual reason to be here.
    /// Calls back on the main queue with what could be read; an empty array
    /// means cancelled.
    static func run(completion: @escaping ([AppEntry]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = localized("Add Apps to Roost")
        panel.prompt = "Add"
        panel.message = "Choose one or more applications."
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        // An .app is a directory on disk. Leaving packages alone and asking
        // for files of type application is what makes one selectable as a
        // single thing rather than something to descend into.
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]

        // LSUIElement apps are not active, and an inactive app's open panel
        // opens behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { completion([]); return }

            var seen = Set<String>()
            let entries = panel.urls.compactMap(entry(for:)).filter { seen.insert($0.bundleID).inserted }
            completion(entries)
        }
    }
}
