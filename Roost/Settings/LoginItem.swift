import Foundation
import ServiceManagement

/// Whether Roost starts when the Mac does.
///
/// `SMAppService.mainApp`, which needs no helper bundle and no launchd plist —
/// the legacy `SMLoginItemSetEnabled` path in Kit's version is gone with the
/// macOS versions that needed it (Roost requires 14).
///
/// The guard is the part that matters. SMAppService records the *path* of the
/// bundle that registers, so registering from Xcode points the login item at
/// DerivedData. macOS then starts that copy at every login — and because the
/// next build replaces it, its code signature changes, every Accessibility and
/// Input Monitoring grant is invalidated, and macOS asks for permission again
/// at the next login, for ever. It also freezes the version the updater
/// compares against, so no release is ever seen as newer. Both of those
/// happened on a real machine, which is why registering from a build directory
/// is refused rather than warned about.
enum LoginItem {

    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    guard !isRunningFromBuildDirectory else {
                        NSLog("Roost: refusing a login item for \(Bundle.main.bundleURL.path) — move it to /Applications first")
                        return
                    }
                    // Re-registering a registered service throws; unregister
                    // first so turning it off and on again is not an error.
                    if SMAppService.mainApp.status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Roost: could not \(newValue ? "enable" : "disable") start at login: \(error.localizedDescription)")
            }
        }
    }

    /// True when the running bundle is a build product rather than an
    /// installed app.
    static var isRunningFromBuildDirectory: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return ["/DerivedData/", "/Build/Products/", "/build/"].contains { path.contains($0) }
    }

    /// The separate helper application older versions registered.
    ///
    /// Before macOS 13 a login item meant a second bundle inside this one,
    /// registered through `SMLoginItemSetEnabled`. `SMAppService.mainApp`
    /// replaced that, and this identifier exists only so the old
    /// registration can be found and taken down.
    private static let legacyHelperID = "\(Bundle.main.bundleIdentifier ?? "com.sagar.roost").LaunchAtLogin"

    /// Moves a pre-macOS-13 login item to the modern registration, once.
    ///
    /// Someone upgrading from a version that registered the helper bundle
    /// has a login item macOS still honours but that nothing in the app can
    /// see, because `SMAppService.mainApp.status` knows nothing about it. So
    /// the old registration is asked whether it is enabled, the answer is
    /// carried across, and the helper is unregistered.
    ///
    /// `LaunchAtLoginNext` is the marker, and it is the key the previous
    /// implementation used -- a Mac that has already migrated must not do it
    /// again, which would turn the login item back on for someone who had
    /// since switched it off.
    static func migrateLegacyRegistration() {
        let prefs = Preferences.shared
        guard !prefs.exists("LaunchAtLoginNext") else { return }
        prefs.set("LaunchAtLoginNext", true)

        let legacy = SMAppService.loginItem(identifier: legacyHelperID)
        guard legacy.status == .enabled else { return }

        // Carried across before the old one is taken down: if the register
        // fails there is still a login item, which is the safer way round.
        isEnabled = true
        try? legacy.unregister()
    }

    /// Where the installed copy is, if there is one.
    static var installedLocation: URL? {
        let url = URL(fileURLWithPath: "/Applications/\(Bundle.main.bundleURL.lastPathComponent)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
