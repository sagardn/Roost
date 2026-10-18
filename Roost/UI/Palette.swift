import AppKit

/// Roost's colours, and the load ramp that picks between them.
///
/// These were measured rather than chosen: every pair clears a lightness band,
/// a chroma floor, and a colour-vision-deficiency separation check on both the
/// light and dark chart surfaces. The worst pair is 11.2 under deuteranopia and
/// 16.0 in normal vision, which is why `systemBlue` / `systemOrange` /
/// `systemRed` are not used — orange sat at lightness 0.765, well outside the
/// band, so the middle zone shouted over the other two, and red against orange
/// measured only 13.1 under deuteranopia.
///
/// They lived in `Kit/extensions.swift` because that is where the colour
/// extensions were, but they are Roost's own work. Here, the independent
/// monitor can use them without importing the framework it is replacing.
extension NSColor {

    // MARK: - Load, in three zones

    /// Comfortable. Also the download series.
    static var roostCalm: NSColor { RoostColors.calm.color }
    /// Working. Also the upload series — deliberately, since a processor or
    /// memory popup never shows an upload series, and the network markers carry
    /// an arrow, so nothing ever reads as both at once.
    static var roostWarning: NSColor { RoostColors.warning.color }
    /// Out of room.
    static var roostCritical: NSColor { RoostColors.critical.color }

    // MARK: - Series

    static var roostAmber: NSColor { roostWarning }
    static let roostBlue = NSColor(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 1)
    static let roostMagenta = NSColor(red: 0xC6 / 255, green: 0x4D / 255, blue: 0x9C / 255, alpha: 1)
    static let roostOlive = NSColor(red: 0x7A / 255, green: 0x9E / 255, blue: 0x23 / 255, alpha: 1)
}

/// How a 0...1 reading should be drawn.
///
/// Six bands rather than three: the colour changes at 30 / 70 / 90 and the
/// weight steps within each zone, so a reading climbing through a zone is
/// visible before it changes colour. Charts and menu bar numbers share it, so
/// a line and the figure beside it can never disagree about what counts as
/// busy.
struct LoadBand {
    let color: NSColor
    let weight: NSFont.Weight

    /// `reversed` is for readings where low is the bad end — battery charge,
    /// and nothing else.
    static func of(_ value: Double, reversed: Bool = false) -> LoadBand {
        let load = reversed ? 1 - value : value
        switch load {
        case ..<0.30: return LoadBand(color: .roostCalm, weight: .regular)
        case ..<0.50: return LoadBand(color: .roostCalm, weight: .semibold)
        case ..<0.70: return LoadBand(color: .roostWarning, weight: .regular)
        case ..<0.80: return LoadBand(color: .roostWarning, weight: .semibold)
        case ..<0.90: return LoadBand(color: .roostCritical, weight: .regular)
        default: return LoadBand(color: .roostCritical, weight: .bold)
        }
    }
}

/// The three load colours, each the measured default unless the user has
/// chosen their own in Settings.
///
/// The defaults above are the validated set; a user's choice is theirs and
/// is not re-validated -- the Settings row offers a reset for when a choice
/// turns out not to read on their wallpaper.
enum RoostColors: String, CaseIterable {
    case calm, warning, critical

    /// The validated defaults, as hex so Settings can show and restore them.
    var defaultHex: String {
        switch self {
        case .calm:     return "#0E9BA8"
        case .warning:  return "#CE7C00"
        case .critical: return "#C9302C"
        }
    }

    /// Where the user's choice is stored, as "#RRGGBB".
    var key: String { "color_\(rawValue)" }

    var hex: String {
        UserDefaults.standard.string(forKey: key).flatMap(Self.normalised) ?? defaultHex
    }

    var isCustom: Bool { hex != defaultHex }

    /// Read on every draw, so it is cached against the stored string: a
    /// defaults lookup is a dictionary read, building an NSColor per figure
    /// per second is not. And it must be the *same* object while the choice
    /// is unchanged, because charts compare colours to tell zones apart.
    var color: NSColor {
        let wanted = hex
        if let cached = Self.cache[self], cached.hex == wanted { return cached.color }
        let made = Self.color(fromHex: wanted) ?? Self.color(fromHex: defaultHex)!
        Self.cache[self] = (wanted, made)
        return made
    }

    /// nil restores the default.
    func set(hex: String?) {
        if let hex, let clean = Self.normalised(hex), clean != defaultHex {
            UserDefaults.standard.set(clean, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static let didChange = Notification.Name("RoostColorsDidChange")

    /// Whether the menu bar figures and arrows take these colours at all.
    /// Off draws them in the bar's own ink, white on a dark bar, for anyone
    /// who wants the menu bar plain. On by default: the colour is what sets
    /// Roost apart. The popups keep their colours either way -- there the
    /// colour is the reading's meaning, not decoration on a shared bar.
    static var menuBarColoured: Bool {
        get { UserDefaults.standard.object(forKey: menuBarColouredKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: menuBarColouredKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let menuBarColouredKey = "menubar_coloured"

    private static var cache: [RoostColors: (hex: String, color: NSColor)] = [:]

    // MARK: Hex

    /// "#RRGGBB", upper case, from "#rgb", "rrggbb", " #RRGGBB " and the
    /// like; nil for anything that is not a colour. One spelling, so a
    /// stored value and the field showing it can be compared as strings.
    static func normalised(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 else { return nil }
        return "#" + digits
    }

    /// sRGB, the space hex codes are written in.
    static func color(fromHex text: String) -> NSColor? {
        guard let clean = normalised(text),
              let value = UInt32(clean.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// nil for a colour with no sRGB form -- a pattern from the picker's
    /// image tab -- rather than a made-up hex.
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

/// Where a reading turns warning and where it turns critical, per kind of
/// reading. The menu bar colour and weight, and the popups' verdicts, all
/// step here, so none of them can disagree about where warning starts.
///
/// Steps, not a gradient. A continuous blend between the three colours was
/// built and dropped at the user's call, on measurement: mixed in OKLab the
/// teal-to-amber midpoint is a low-chroma grey, so a CPU at 37% read as
/// disabled rather than busier; mixed in OKLCH the short way round it passes
/// through green, which all but vanished on a green wallpaper (#5B7F3E);
/// the long way round is a rainbow. A figure that is always exactly one of
/// the three colours reads on any wallpaper.
struct SeverityBands: Equatable {
    let warning: Double
    let critical: Double

    /// 0...1 loads, the ramp's colour zones (`LoadBand`: 50 / 80).
    static let load = SeverityBands(warning: 0.50, critical: 0.80)
    /// A volume's fill. macOS itself starts warning near the end, not at
    /// 70%, and a disk that full is a chore, not an emergency.
    static let disk = SeverityBands(warning: 0.90, critical: 0.95)
    /// Degrees Celsius. Apple silicon runs at 70-90 °C under sustained load
    /// as a matter of course and throttles itself past about 100.
    static let temperature = SeverityBands(warning: 85, critical: 95)

    /// 0 calm, 1 warning, 2 critical.
    func zone(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return value >= critical ? 2 : value >= warning ? 1 : 0
    }
}

extension Double {
    /// The band for a 0...1 reading.
    func loadBand(reversed: Bool = false) -> LoadBand { LoadBand.of(self, reversed: reversed) }
}
