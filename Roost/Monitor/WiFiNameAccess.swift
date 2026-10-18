import AppKit
import CoreLocation

/// Permission to read the Wi-Fi network's name.
///
/// Since macOS 14, CoreWLAN's `ssid()` returns nil for an app without
/// Location access -- the name of a network can place a Mac on a map. Roost
/// declared no location use and never asked, so the system never offered the
/// choice and the popup's "allow Location" had nothing to allow. This asks,
/// when the Allow button is pressed and not before. Roost reads the network's
/// name with it and nothing else: it never asks CoreLocation where the Mac is.
final class WiFiNameAccess: NSObject, CLLocationManagerDelegate {

    static let shared = WiFiNameAccess()

    enum State { case notAsked, allowed, denied, servicesOff }

    /// Whether Location Services is on for the whole Mac. Off, macOS
    /// reports every app as refused without asking -- measured on this Mac,
    /// where it was off and a copy that had never asked read as denied. Read
    /// off the main thread, because Apple warns this call can stall it.
    private(set) var servicesEnabled: Bool?

    func checkServices() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                guard let self, self.servicesEnabled != enabled else { return }
                self.servicesEnabled = enabled
                self.onChange?()
            }
        }
    }

    /// Called on the main thread when the answer changes -- the popup
    /// re-reads the network's details then, instead of waiting for its next
    /// refresh.
    var onChange: (() -> Void)?

    /// Made on first use. Creating one asks nothing; only `request()` does.
    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    var state: State {
        if servicesEnabled == false { return .servicesOff }
        switch manager.authorizationStatus {
        case .notDetermined:                return .notAsked
        case .authorizedAlways, .authorized: return .allowed
        default:                            return .denied
        }
    }

    /// The system's own prompt. Roost has no Dock icon and is usually in the
    /// background when the popup's button is pressed, so it comes forward
    /// first or the prompt opens behind the app in front.
    func request() {
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
    }

    /// Once refused, macOS does not ask again; the switch is in System
    /// Settings ▸ Privacy & Security ▸ Location Services.
    static func openSettings() {
        for address in ["x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
                        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
