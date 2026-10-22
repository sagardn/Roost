import AppKit

/// Opens a page of System Settings.
///
/// For the settings Roost reports on but will not change itself -- FileVault,
/// the firewall, what runs in the background -- the useful act is putting
/// somebody on the page that has the switch.
///
/// The identifiers are the ones macOS 13 introduced with the redesigned
/// Settings, and they are not a public contract: a page renamed in a later
/// release opens Settings on whatever it last showed rather than failing.
/// So each page is named in one place, here, where a rename is one line.
enum SettingsLink {

    case loginItems, privacySecurity, fileVault, firewall, softwareUpdate, fullDiskAccess

    private var identifier: String {
        switch self {
        case .loginItems:      return "com.apple.LoginItems-Settings.extension"
        case .privacySecurity: return "com.apple.settings.PrivacySecurity.extension"
        case .fileVault:       return "com.apple.settings.PrivacySecurity.extension?FileVault"
        case .firewall:        return "com.apple.Network-Settings.extension?Firewall"
        case .softwareUpdate:  return "com.apple.Software-Update-Settings.extension"
        case .fullDiskAccess:  return "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        }
    }

    func open() {
        guard let url = URL(string: "x-apple.systempreferences:" + identifier) else { return }
        NSWorkspace.shared.open(url)
    }
}
