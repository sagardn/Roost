import Foundation

/// How often Roost looks for a new release.
///
/// The raw values are the strings already stored under `update-interval`, so
/// a Mac that has been running Roost keeps whatever it was set to. The two
/// separators are part of that: they were menu dividers that the old settings
/// window rendered, and they are still accepted here because an old
/// configuration could have one saved -- `interval(from:)` reads them as
/// "no schedule" rather than refusing the value and resetting the user to a
/// default they did not choose.
enum UpdateInterval: String, CaseIterable {
    case silent = "Silent"
    case atStart = "At start"
    case oncePerDay = "Once per day"
    case oncePerWeek = "Once per week"
    case oncePerMonth = "Once per month"
    case never = "Never"

    /// What the settings window offers, in order.
    static var offered: [UpdateInterval] { allCases }

    /// Reads a stored value, tolerating the two separator strings the old
    /// settings window could leave behind.
    static func interval(from stored: String) -> UpdateInterval? {
        if stored.hasPrefix("separator") { return nil }
        return UpdateInterval(rawValue: stored)
    }

    /// Whether a check should run without anybody asking.
    var isAutomatic: Bool {
        switch self {
        case .never: return false
        default:     return true
        }
    }
}

extension UpdateInterval {

    /// Whether this fork has a release feed worth checking.
    ///
    /// While false the app never checks, and the default below is Never. Two
    /// reasons, the second being the serious one: there is nothing to check
    /// against an empty releases page, so a check can only fail silently once
    /// a launch forever; and "Silent" does not merely check -- it downloads
    /// and installs, replacing the running application without asking.
    /// Shipping that switched on is not a default anybody chose.
    static let updatesEnabled = true

    /// What a fresh install checks at.
    ///
    /// A daily check that tells you and waits, rather than one that replaces
    /// the app underneath you.
    static var defaultStored: String {
        (updatesEnabled ? UpdateInterval.oncePerDay : .never).rawValue
    }
}
