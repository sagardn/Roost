import Foundation

/// A released version of Roost, as `major.minor.patch`.
///
/// Parsing is deliberately forgiving about the shapes a tag arrives in -- `v1.2.3`,
/// `1.2.3`, `1.2`, `1.2.3-beta.1` -- and deliberately strict about what it
/// compares: only the three numbers, in order. A pre-release suffix is kept for
/// display and ignored for ordering, which is the behaviour that matters here
/// (Roost has never shipped one, and treating `1.2.3-beta` as older than
/// `1.2.3` would silently offer a downgrade if it ever did).
///
/// Replaces the string-splitting comparison in Kit, which compared components
/// as `Int` only after stripping a leading "v" and returned "not newer" for
/// anything it could not parse -- including the empty string, so a failed feed
/// read looked exactly like being up to date.
struct Version: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Anything after the numbers: "beta.1" in `1.2.3-beta.1`. Display only.
    let prerelease: String?

    init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// nil when the string holds no version at all. An unparseable feed must be
    /// an error the caller can see, never a silent "you are up to date".
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        var suffix: String?
        for separator in ["-", "+"] where text.contains(separator) {
            let parts = text.components(separatedBy: separator)
            text = parts[0]
            suffix = parts.dropFirst().joined(separator: separator)
            break
        }

        let numbers = text.components(separatedBy: ".")
        guard (1...3).contains(numbers.count) else { return nil }
        var parsed: [Int] = []
        for part in numbers {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        while parsed.count < 3 { parsed.append(0) }

        self.init(major: parsed[0], minor: parsed[1], patch: parsed[2],
                  prerelease: (suffix?.isEmpty ?? true) ? nil : suffix)
    }

    /// The version this copy of Roost reports.
    static var current: Version? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return Version(raw)
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }
}
