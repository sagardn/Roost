import Foundation

/// Clipboard history's preferences, under `Clipboard_` like every module's.
///
/// Monitoring and the menu bar item are separate switches on purpose. The
/// module's own switch -- `Clipboard_state`, the one in the sidebar -- is
/// whether the item is in the menu bar; `monitoring` is whether anything is
/// captured at all. Somebody can keep history with no menu bar item, reached
/// by its shortcut, or keep the item to browse an old history with capture
/// off.
enum ClipboardSettings {
    private static let prefs = Preferences.shared

    /// Off until somebody turns it on, having read what it does. A clipboard
    /// history keeps passwords and private messages if it is not careful, and
    /// nobody should find one running that they did not start.
    static var monitoring: Bool {
        get { prefs.bool("Clipboard_monitoring", default: false) }
        set { prefs.set("Clipboard_monitoring", newValue) }
    }

    /// Whether the privacy explanation has been read and accepted once.
    static var privacyAccepted: Bool {
        get { prefs.bool("Clipboard_privacyAccepted", default: false) }
        set { prefs.set("Clipboard_privacyAccepted", newValue) }
    }

    static var captureText: Bool {
        get { prefs.bool("Clipboard_captureText", default: true) }
        set { prefs.set("Clipboard_captureText", newValue) }
    }

    static var captureImages: Bool {
        get { prefs.bool("Clipboard_captureImages", default: true) }
        set { prefs.set("Clipboard_captureImages", newValue) }
    }

    static var keepRichText: Bool {
        get { prefs.bool("Clipboard_keepRichText", default: true) }
        set { prefs.set("Clipboard_keepRichText", newValue) }
    }

    static var showImagePreviews: Bool {
        get { prefs.bool("Clipboard_showImagePreviews", default: true) }
        set { prefs.set("Clipboard_showImagePreviews", newValue) }
    }

    /// Off by default, and the only part of the feature that needs a
    /// permission: sending ⌘V to another app is posting a key event, which
    /// macOS gates behind Accessibility.
    static var autoPaste: Bool {
        get { prefs.bool("Clipboard_autoPaste", default: false) }
        set { prefs.set("Clipboard_autoPaste", newValue) }
    }

    static var maximumEntries: Int {
        get { prefs.int("Clipboard_maximumEntries", default: 200) }
        set { prefs.set("Clipboard_maximumEntries", newValue) }
    }

    /// Days. Zero keeps entries until the count pushes them out.
    static var retentionDays: Int {
        get { prefs.int("Clipboard_retentionDays", default: 30) }
        set { prefs.set("Clipboard_retentionDays", newValue) }
    }

    static var retentionIncludesPinned: Bool {
        get { prefs.bool("Clipboard_retentionIncludesPinned", default: false) }
        set { prefs.set("Clipboard_retentionIncludesPinned", newValue) }
    }

    static var persistent: Bool {
        get { prefs.bool("Clipboard_persistent", default: true) }
        set { prefs.set("Clipboard_persistent", newValue) }
    }

    static var clearUnpinnedOnQuit: Bool {
        get { prefs.bool("Clipboard_clearOnQuit", default: false) }
        set { prefs.set("Clipboard_clearOnQuit", newValue) }
    }

    /// How many entries the menu bar popup lists.
    static var popupCount: Int {
        get { prefs.int("Clipboard_popupCount", default: 8) }
        set { prefs.set("Clipboard_popupCount", newValue) }
    }

    /// Apps whose copies are ignored while they are in front. The password
    /// managers are there from the start: most of them also mark what they
    /// copy as concealed, and this is the belt to those braces.
    static var excludedApps: [String] {
        get { prefs.strings("Clipboard_excludedApps") ?? defaultExcludedApps }
        set { prefs.set("Clipboard_excludedApps", newValue) }
    }

    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc"
    ]

    /// The shortcut, stored where `ShortcutRecorder` stores every module's.
    static var shortcut: [UInt16] {
        (UserDefaults.standard.array(forKey: "Clipboard_popupShortcut") as? [Int])?.map { UInt16($0) } ?? []
    }

    /// Every option `restoreDefaults` resets. Not monitoring, not the menu
    /// bar item and not the shortcut -- those are on/off choices somebody
    /// made on purpose -- and never the history itself.
    private static let resettable = [
        "Clipboard_captureText", "Clipboard_captureImages", "Clipboard_keepRichText",
        "Clipboard_showImagePreviews", "Clipboard_autoPaste", "Clipboard_maximumEntries",
        "Clipboard_retentionDays", "Clipboard_retentionIncludesPinned", "Clipboard_persistent",
        "Clipboard_clearOnQuit", "Clipboard_popupCount", "Clipboard_excludedApps"
    ]

    static func restoreDefaults() {
        resettable.forEach { prefs.set($0, nil) }
    }

    static func isClipboardKey(_ key: String?) -> Bool { key?.hasPrefix("Clipboard_") ?? true }

    /// The settings the service works from, read once per use.
    static var snapshot: ClipboardOptions {
        ClipboardOptions(monitoring: monitoring,
                         capture: .init(captureText: captureText, captureImages: captureImages,
                                        keepRichText: keepRichText),
                         limits: .init(maximumEntries: maximumEntries,
                                       retention: retentionDays > 0 ? TimeInterval(retentionDays) * 86_400 : nil,
                                       retentionIncludesPinned: retentionIncludesPinned),
                         persistent: persistent,
                         excludedApps: Set(excludedApps))
    }
}

/// The settings as one value, so the service can be driven by a test with
/// settings written down rather than read from the user's defaults.
struct ClipboardOptions: Equatable {
    var monitoring: Bool
    var capture: ClipboardCapture.Options
    var limits: ClipboardHistory.Limits
    var persistent: Bool
    var excludedApps: Set<String>
}
