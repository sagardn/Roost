import Foundation

/// Where the helper is, and what it is a helper for.
///
/// Split out from `main.swift` so it can be checked against paths written
/// down rather than against wherever this copy happens to be installed. The
/// arithmetic is the whole job of this target and it is off-by-one-able:
/// get it wrong and the login item launches the wrong thing, or nothing, on
/// a machine nobody is watching at the time.
enum LoginHelper {

    /// The suffix the helper's bundle identifier adds to the app's.
    ///
    /// Must match `PRODUCT_BUNDLE_IDENTIFIER` for this target. It is a
    /// constant rather than a string literal at the use site so the two
    /// places that care about it cannot drift apart silently.
    static let identifierSuffix = ".LaunchAtLogin"

    /// How deep inside the app bundle a login item lives.
    ///
    /// `Roost.app/Contents/Library/LoginItems/LaunchAtLogin.app` — four
    /// directories down, fixed by the layout `SMAppService` expects rather
    /// than by anything this chooses.
    private static let depth = 4

    /// The app bundle this helper is embedded in.
    ///
    /// There is no API that asks "which app contains me", so it is counted
    /// rather than searched. Counting is then *checked*: a result that is not
    /// an `.app` means the helper was copied somewhere else, or the bundle
    /// layout changed under us, and launching whatever happens to sit at
    /// that path would be worse than launching nothing. nil, never a guess.
    static func hostApp(forHelperAt helper: URL) -> URL? {
        var url = helper.standardizedFileURL
        for _ in 0..<depth {
            let parent = url.deletingLastPathComponent()
            // Walked off the top of the filesystem: "/" is its own parent, so
            // without this the loop reports "/" as an app bundle.
            guard parent.path != url.path else { return nil }
            url = parent
        }
        guard url.pathExtension == "app" else { return nil }
        return url
    }

    /// The containing app's bundle identifier, from the helper's own.
    ///
    /// Suffix removal, not a search-and-replace of the suffix anywhere in the
    /// string: an app legitimately identified `com.example.LaunchAtLogin.Tool`
    /// would otherwise have the middle cut out of it and be asked about under
    /// a name nothing answers to.
    static func hostBundleID(forHelperID identifier: String) -> String? {
        guard identifier.hasSuffix(identifierSuffix) else { return nil }
        let host = String(identifier.dropLast(identifierSuffix.count))
        return host.isEmpty ? nil : host
    }
}
