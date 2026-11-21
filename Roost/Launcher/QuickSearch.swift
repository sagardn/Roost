import Foundation

/// What the search panel can answer besides an app: a sum, a unit
/// conversion, or a system action.
///
/// The panel's job is still to switch apps, so these only appear when the
/// query is unmistakably one of them -- `12*8` is a sum, `5 km in miles` is
/// a conversion, `lock` is an action -- and never for a query that could be
/// the start of an app's name. Typing `sa` must still find Safari first.
enum QuickSearch {

    enum Result: Equatable {
        /// A value to copy: "101", "3.107 mi".
        case answer(title: String, copy: String)
        case action(Action)
        /// Send sound to this output.
        case output(AudioOutputs.Device)
        /// Keep the Mac awake for this many seconds.
        case keepAwake(for: TimeInterval)
        /// Start a timer, with what it is for if one was given.
        case timer(seconds: TimeInterval, label: String?)
        /// Stop a running timer.
        case cancelTimer(UUID)
        /// Set the output volume, 0...100.
        case volume(Int)
        /// A line of the help list. Choosing it puts `fill` in the search
        /// field rather than doing anything, so the example can be read,
        /// changed and then run.
        case suggest(title: String, fill: String, symbol: String)

        /// A help row fills the search field instead of running anything.
        var fill: String? {
            if case .suggest(_, let fill, _) = self { return fill }
            return nil
        }
    }

    /// The rows that go above the apps. `outputs` is the Mac's sound
    /// outputs, passed in so this stays a function of what it is given.
    static func results(for query: String, outputs: [AudioOutputs.Device] = []) -> [Result] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        if let conversion = convert(text) {
            return [.answer(title: "\(text) = \(conversion)", copy: conversion)]
        }
        if let value = calculate(text) {
            let shown = format(value)
            return [.answer(title: "\(text) = \(shown)", copy: shown)]
        }
        // "?" or "help": everything the panel can do besides apps.
        if text == "?" || text.lowercased() == "help" { return help() }
        // "awake 45m": exactly that, and nothing else.
        if let duration = awakeDuration(text) { return [.keepAwake(for: duration)] }
        if let request = timerRequest(text) { return [.timer(seconds: request.seconds, label: request.label)] }
        if let level = volumeLevel(text) { return [.volume(level)] }
        // "timer" alone: the ones running, to stop.
        if text.lowercased() == "timer" || text.lowercased() == "timers" {
            return RoostTimers.shared.running.map { .cancelTimer($0.id) }
        }

        var found: [Result] = Action.matching(text).map { .action($0) }
        // "awake" alone: until turned off, or for an hour -- the length most
        // keep-awake apps lead with. Not while it is already on, when the
        // row there is the one that turns it off.
        if found.contains(.action(.keepAwake)), !KeepAwake.shared.isOn {
            found.append(.keepAwake(for: 3600))
        }
        found += AudioOutputs.matching(text, in: outputs).primary.map { .output($0) }
        return found
    }

    /// The rows that go below the apps: outputs found by name alone. See
    /// `AudioOutputs.matching` for why they are kept under the apps.
    static func trailing(for query: String, outputs: [AudioOutputs.Device]) -> [Result] {
        AudioOutputs.matching(query.trimmingCharacters(in: .whitespaces), in: outputs)
            .secondary.map { .output($0) }
    }

    // MARK: - How long to stay awake

    /// The time in "awake 45m", "keep awake for 2 hours", "caffeinate 1h30m",
    /// or nil when the query is not one of those.
    ///
    /// Up to a day: a longer keep-awake is a setting, not a moment's
    /// request, and a typo of "200h" should not hold the Mac awake for a week.
    static func awakeDuration(_ text: String) -> TimeInterval? {
        let lead = #"^\s*(?:keep\s+(?:the\s+)?(?:mac\s+)?)?(?:awake|caffeinate|stay\s+awake)\s+(?:for\s+)?"#
        guard let rest = after(lead, in: text), let parsed = duration(rest), parsed.rest.isEmpty,
              parsed.seconds <= 86_400 else { return nil }
        return parsed.seconds
    }

    /// "timer 10m", "timer 25 minutes tea", "set a timer for 1h30m": the
    /// time, and whatever follows it as what the timer is for.
    static func timerRequest(_ text: String) -> (seconds: TimeInterval, label: String?)? {
        let lead = #"^\s*(?:set\s+(?:a\s+)?)?timer\s+(?:for\s+)?"#
        guard let rest = after(lead, in: text), let parsed = duration(rest),
              parsed.seconds <= 86_400 else { return nil }
        // The label as it was typed, not lower-cased: "tea" or "Call Mum".
        let label = String(text.suffix(parsed.rest.count)).trimmingCharacters(in: .whitespaces)
        let cleaned = label.replacingOccurrences(of: #"^(?:for|to|called)\s+"#, with: "",
                                                 options: [.regularExpression, .caseInsensitive])
        return (parsed.seconds, cleaned.isEmpty ? nil : cleaned)
    }

    /// "vol 30", "volume 30%", "set volume to 75": a level from 0 to 100.
    static func volumeLevel(_ text: String) -> Int? {
        let pattern = #"^\s*(?:set\s+)?(?:vol|volume)\s+(?:to\s+)?([0-9]{1,3})\s*%?\s*$"#
        guard let match = text.lowercased().range(of: pattern, options: .regularExpression) else { return nil }
        let digits = text.lowercased()[match].filter(\.isNumber)
        guard let level = Int(digits), level <= 100 else { return nil }
        return level
    }

    /// What follows `lead` in `text`, lower-cased and trimmed; nil if `text`
    /// does not start with it, or nothing follows.
    private static func after(_ lead: String, in text: String) -> String? {
        let lower = text.lowercased()
        guard let start = lower.range(of: lead, options: .regularExpression) else { return nil }
        let rest = String(lower[start.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// A length of time at the start of `text`, in any of the ways people
    /// abbreviate hours, minutes and seconds -- "1h30m", "90 min", "1.5
    /// hours", "1 hour and 15 minutes" -- and what is left after it.
    static func duration(_ text: String) -> (seconds: TimeInterval, rest: String)? {
        let part = #"^([0-9]+(?:\.[0-9]+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)(?![a-z])\s*(?:and\s+)?"#
        var rest = text.lowercased().trimmingCharacters(in: .whitespaces)
        var seconds: TimeInterval = 0
        while let match = try? NSRegularExpression(pattern: part)
                .firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let numberRange = Range(match.range(at: 1), in: rest),
              let unitRange = Range(match.range(at: 2), in: rest),
              let all = Range(match.range, in: rest),
              let number = Double(rest[numberRange]) {
            let unit = rest[unitRange]
            seconds += number * (unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            rest = String(rest[all.upperBound...])
        }
        return seconds > 0 ? (seconds, rest.trimmingCharacters(in: .whitespaces)) : nil
    }

    // MARK: - Help

    /// Everything the panel does besides apps, one line each with an
    /// example. Nothing on screen said any of it existed: a calculator, a
    /// sound switcher and a timer were there to be found only by somebody
    /// who already knew to type for them.
    static func help() -> [Result] {
        let lines: [(String, String, String)] = [
            (localized("Calculate"), "12*8+5", "equal.circle.fill"),
            (localized("Convert units"), "5 km in miles", "arrow.left.arrow.right.circle.fill"),
            (localized("Switch the sound output"), "sound", "speaker.wave.2.fill"),
            (localized("Set the volume"), "vol 30", "speaker.wave.3.fill"),
            (localized("Mute the sound or the microphone"), "mute", "speaker.slash.fill"),
            (localized("Start a timer"), "timer 10m", "timer"),
            (localized("Keep the Mac awake"), "awake 1h", "cup.and.saucer.fill"),
            (localized("Pick a colour from the screen"), "color", "eyedropper"),
            (localized("Test the internet speed"), "speed test", "speedometer"),
            (localized("Eject every disk"), "eject", "eject.fill"),
            (localized("Lock, sleep, restart or shut down"), "lock", "lock.fill"),
            (localized("Quit every app"), "quit all", "xmark.circle.fill")
        ]
        return lines.map { name, example, symbol in
            .suggest(title: "\(name)  —  \(example)", fill: example, symbol: symbol)
        }
    }

    // MARK: - Calculator

    /// The value of an arithmetic expression, or nil for anything that is
    /// not one -- including a plain number, which is a query, not a sum.
    ///
    /// A parser of its own rather than NSExpression: NSExpression raises an
    /// Objective-C exception on input it does not like ("1+", "abc", a
    /// format string), and an exception is not catchable from Swift -- it
    /// would take the whole app down from a typo in a search box.
    static func calculate(_ text: String) -> Double? {
        let lower = text.lowercased()
        // Something to calculate: an operator between things, or a function.
        let hasOperator = lower.dropFirst().contains { "+-*/×÷^%".contains($0) }
        let hasFunction = Calculator.functions.keys.contains { lower.contains($0 + "(") }
        guard hasOperator || hasFunction, lower.contains(where: \.isNumber) else { return nil }
        var parser = Calculator(lower)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return value
    }

    /// Up to ten significant figures, no trailing zeros, no exponent for
    /// ordinary numbers -- what a person would type back in.
    ///
    /// More than ten where the whole-number part needs them. Ten flat
    /// rounded `1234567890123 + 0.5` to 1234567890000, an answer 123.5 out,
    /// copied as though it were right. Fifteen is as far as a Double's
    /// digits can be trusted.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        let whole = abs(value) >= 1 ? Int(log10(abs(value))) + 1 : 0
        formatter.maximumSignificantDigits = min(15, max(10, whole + 2))
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    struct Calculator {
        private let chars: [Character]
        private var at = 0
        /// How deep the brackets and signs go. Each level is a recursion,
        /// and about thirty thousand -- one long paste of "(((" -- overflowed
        /// the stack and took the whole app down from the search field.
        private var depth = 0
        private static let deepest = 200

        static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { abs($0) }, "round": { $0.rounded() },
            "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            "ln": { log($0) }, "log": { log10($0) }
        ]

        init(_ text: String) {
            // A comma before exactly three digits groups thousands, as in
            // 1,000; any other comma is a decimal point, as half the world
            // writes one. Every comma was deleted, so "1,5*2" was 15*2 = 30
            // -- shown as the answer, and copied as one.
            let grouped = text.replacingOccurrences(of: #",(?=[0-9]{3}(?![0-9]))"#, with: "",
                                                    options: .regularExpression)
            chars = Array(grouped.replacingOccurrences(of: "×", with: "*")
                              .replacingOccurrences(of: "÷", with: "/")
                              .replacingOccurrences(of: ",", with: ".")
                              .filter { !$0.isWhitespace })
        }

        /// The whole input as one expression, or nil if anything is left over.
        mutating func parse() -> Double? {
            guard let value = sum(), at == chars.count else { return nil }
            return value
        }

        private var next: Character? { at < chars.count ? chars[at] : nil }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = next, op == "+" || op == "-" {
                at += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = unary() else { return nil }
            while let op = next, op == "*" || op == "/" || op == "%" {
                at += 1
                guard let rhs = unary() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default:  value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        /// Right-associative: 2^3^2 is 2^9. The exponent may carry a sign,
        /// as in 2^-1; the base may not -- that sign belongs to the power.
        private mutating func power() -> Double? {
            guard let base = atom() else { return nil }
            if next == "^" {
                at += 1
                guard let exponent = unary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        /// A sign applies to the power after it: -2^2 is -(2^2) = -4, as on
        /// paper and in Spotlight. It was applied to the 2 first, giving 4.
        private mutating func unary() -> Double? {
            guard next == "-" || next == "+" else { return power() }
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.deepest else { return nil }
            let sign = next
            at += 1
            return sign == "-" ? unary().map { -$0 } : unary()
        }

        private mutating func atom() -> Double? {
            guard let c = next else { return nil }
            if c == "(" {
                depth += 1
                defer { depth -= 1 }
                guard depth <= Self.deepest else { return nil }
                at += 1
                guard let value = sum(), next == ")" else { return nil }
                at += 1
                return value
            }
            if c.isNumber || c == "." {
                let start = at
                while let d = next, d.isNumber || d == "." { at += 1 }
                return Double(String(chars[start..<at]))
            }
            if c.isLetter {
                let start = at
                while let d = next, d.isLetter { at += 1 }
                let word = String(chars[start..<at])
                if word == "pi" || word == "π" { return .pi }
                if word == "e" { return M_E }
                guard let function = Self.functions[word], next == "(" else { return nil }
                depth += 1
                defer { depth -= 1 }
                guard depth <= Self.deepest else { return nil }
                at += 1
                guard let argument = sum(), next == ")" else { return nil }
                at += 1
                return function(argument)
            }
            return nil
        }
    }

    // MARK: - Units

    /// "5 km in miles" -> "3.107 mi". nil for anything else, including two
    /// units that measure different things.
    static func convert(_ text: String) -> String? {
        let pattern = #"^\s*(-?[0-9]*\.?[0-9]+)\s*([a-zA-Z°µ/]+)\s+(?:in|to|as|into)\s+([a-zA-Z°µ/]+)\s*$"#
        guard let match = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text),
              let value = Double(text[numberRange]),
              let from = units[text[fromRange].lowercased()],
              let to = units[text[toRange].lowercased()],
              type(of: from) == type(of: to)
        else { return nil }

        let converted = Measurement(value: value, unit: from).converted(to: to)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberFormatter.maximumFractionDigits = 3
        // Below one, three significant figures rather than three decimals:
        // "1 mm in km" was "0 km", offered and copied as the answer.
        if converted.value != 0, abs(converted.value) < 1 {
            formatter.numberFormatter.usesSignificantDigits = true
            formatter.numberFormatter.maximumSignificantDigits = 3
        }
        formatter.numberFormatter.usesGroupingSeparator = false
        return formatter.string(from: converted)
    }

    /// Spellings a person types, to Foundation's units.
    static let units: [String: Dimension] = {
        var map: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { names.forEach { map[$0] = unit } }
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters", "millimetre", "millimetres")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.inches, "in", "inch", "inches")
        add(UnitLength.feet, "ft", "foot", "feet")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitTemperature.celsius, "c", "°c", "celsius")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")
        add(UnitInformationStorage.bytes, "b", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte", "kilobytes")
        add(UnitInformationStorage.megabytes, "mb", "megabyte", "megabytes")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte", "gigabytes")
        add(UnitInformationStorage.terabytes, "tb", "terabyte", "terabytes")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters", "millilitre", "millilitres")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.cups, "cup", "cups")
        add(UnitSpeed.kilometersPerHour, "kmh", "km/h", "kph")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s")
        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        return map
    }()

    // MARK: - Actions

    enum Action: String, CaseIterable {
        case lockScreen, sleep, sleepDisplay, screenSaver, toggleDarkMode, emptyBin
        case keepAwake, ejectAll
        case restart, shutDown, logOut, quitAll
        case pickColor, muteSound, muteMic, speedTest

        var title: String {
            switch self {
            case .lockScreen:     return localized("Lock Screen")
            case .sleep:          return localized("Sleep")
            case .sleepDisplay:   return localized("Sleep Display")
            case .screenSaver:    return localized("Start Screen Saver")
            case .toggleDarkMode: return localized("Toggle Dark Mode")
            case .emptyBin:       return localized("Empty Bin")
            // Says what choosing it will do, which flips with the state.
            case .keepAwake:
                return KeepAwake.shared.isOn ? localized("Allow Sleep Again") : localized("Keep Mac Awake")
            case .ejectAll:       return localized("Eject All Disks")
            case .restart:        return localized("Restart")
            case .shutDown:       return localized("Shut Down")
            case .logOut:         return localized("Log Out")
            case .quitAll:        return localized("Quit All Apps")
            case .pickColor:      return localized("Pick a Colour from the Screen")
            case .muteSound:
                return AudioControl.isOutputMuted ? localized("Turn Sound Back On") : localized("Mute Sound")
            case .muteMic:
                return AudioControl.isInputMuted ? localized("Turn Microphone Back On") : localized("Mute Microphone")
            case .speedTest:      return localized("Test Internet Speed")
            }
        }

        var symbol: String {
            switch self {
            case .lockScreen:     return "lock.fill"
            case .sleep:          return "moon.zzz.fill"
            case .sleepDisplay:   return "display"
            case .screenSaver:    return "sparkles.tv"
            case .toggleDarkMode: return "circle.lefthalf.filled"
            case .emptyBin:       return "trash.fill"
            case .keepAwake:      return KeepAwake.shared.isOn ? "moon.zzz" : "cup.and.saucer.fill"
            case .ejectAll:       return "eject.fill"
            case .restart:        return "arrow.clockwise.circle.fill"
            case .shutDown:       return "power.circle.fill"
            case .logOut:         return "rectangle.portrait.and.arrow.right"
            case .quitAll:        return "xmark.circle.fill"
            case .pickColor:      return "eyedropper"
            case .muteSound:      return AudioControl.isOutputMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            case .muteMic:        return AudioControl.isInputMuted ? "mic.fill" : "mic.slash.fill"
            case .speedTest:      return "speedometer"
            }
        }

        /// English words that find it, whatever the title is translated to.
        var keywords: [String] {
            switch self {
            case .lockScreen:     return ["lock", "lock screen"]
            case .sleep:          return ["sleep", "suspend"]
            case .sleepDisplay:   return ["sleep display", "display off", "screen off"]
            case .screenSaver:    return ["screen saver", "screensaver", "saver"]
            case .toggleDarkMode: return ["dark mode", "light mode", "dark", "appearance"]
            case .emptyBin:       return ["empty bin", "empty trash", "bin", "trash"]
            case .keepAwake:      return ["keep awake", "awake", "stay awake", "caffeinate",
                                          "no sleep", "allow sleep"]
            case .ejectAll:       return ["eject", "eject all", "unmount"]
            case .restart:        return ["restart", "reboot"]
            case .shutDown:       return ["shut down", "shutdown", "power off", "turn off"]
            case .logOut:         return ["log out", "logout", "sign out"]
            case .quitAll:        return ["quit all", "quit all apps", "close all apps"]
            case .pickColor:      return ["color", "colour", "pick color", "pick colour", "color picker",
                                          "colour picker", "eyedropper", "hex"]
            case .muteSound:      return ["mute", "mute sound", "unmute", "unmute sound", "silence"]
            // Never "mic" alone: it is the start of every Microsoft app.
            case .muteMic:        return ["mute mic", "mute microphone", "unmute mic", "unmute microphone"]
            case .speedTest:      return ["speed test", "speedtest", "internet speed", "network speed",
                                          "test speed", "wifi speed"]
            }
        }

        /// Which running apps Quit All Apps quits: the ones in the Dock and the
        /// app switcher, except Finder -- which macOS relaunches at once, and is
        /// not "an app somebody has open" -- and Roost itself, which is where the
        /// request came from. Menu bar utilities and background agents stay.
        static func quits(bundleID: String?, regular: Bool, own: String?) -> Bool {
            guard regular, let bundleID else { return false }
            return bundleID != "com.apple.finder" && bundleID != own
        }

        /// The ones that end what somebody is doing. They ask first, and need
        /// four letters rather than three: "log" is as likely the start of
        /// Logic Pro, and "res" of a resume being looked for.
        var endsSession: Bool {
            switch self {
            case .restart, .shutDown, .logOut, .quitAll: return true
            default: return false
            }
        }

        /// Letters needed before it is offered. Four for the ones that end a
        /// session, and for the colour picker -- "col" is as likely
        /// ColorSync Utility. Three for the rest, as before.
        var minimumLength: Int {
            endsSession || self == .pickColor ? 4 : 3
        }

        /// An action whose title or a keyword starts with the query, from
        /// three letters: two would put "Sleep" above Slack for "sl".
        static func matching(_ query: String) -> [Action] {
            let q = query.lowercased()
            guard q.count >= 3 else { return [] }
            return allCases.filter { action in
                guard q.count >= action.minimumLength else { return false }
                return ([action.title.lowercased()] + action.keywords).contains { $0.hasPrefix(q) }
            }
        }
    }
}
