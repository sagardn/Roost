import Foundation

/// Looks a string up in Roost's own translations.
///
/// The 42 `.lproj` folders live in `Roost/Supporting Files`, which is the app
/// bundle — `NSLocalizedString` resolves against `Bundle.main`, so replacing
/// Kit's helper loses none of them.
///
/// `%0`, `%1` … are substituted positionally, which is the convention the
/// existing translations are written in ("Number of cores: %0"). Deliberately
/// not `String(format:)`: the translated strings use this numbering, and
/// `%0` is not a valid format specifier.
func localized(_ key: String, _ parameters: String...) -> String {
    var string = NSLocalizedString(key, comment: "")
    for (index, parameter) in parameters.enumerated() {
        string = string.replacingOccurrences(of: "%\(index)", with: parameter)
    }
    return string
}
