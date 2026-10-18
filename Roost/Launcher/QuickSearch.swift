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
    }

    static func results(for query: String) -> [Result] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        if let conversion = convert(text) {
            return [.answer(title: "\(text) = \(conversion)", copy: conversion)]
        }
        if let value = calculate(text) {
            let shown = format(value)
            return [.answer(title: "\(text) = \(shown)", copy: shown)]
        }
        return Action.matching(text).map { .action($0) }
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
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumSignificantDigits = 10
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    struct Calculator {
        private let chars: [Character]
        private var at = 0

        static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { abs($0) }, "round": { $0.rounded() },
            "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            "ln": { log($0) }, "log": { log10($0) }
        ]

        init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: "×", with: "*")
                              .replacingOccurrences(of: "÷", with: "/")
                              .replacingOccurrences(of: ",", with: "")
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
            guard var value = power() else { return nil }
            while let op = next, op == "*" || op == "/" || op == "%" {
                at += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default:  value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        /// Right-associative: 2^3^2 is 2^9.
        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if next == "^" {
                at += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if next == "-" { at += 1; return unary().map { -$0 } }
            if next == "+" { at += 1; return unary() }
            return atom()
        }

        private mutating func atom() -> Double? {
            guard let c = next else { return nil }
            if c == "(" {
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

        var title: String {
            switch self {
            case .lockScreen:     return localized("Lock Screen")
            case .sleep:          return localized("Sleep")
            case .sleepDisplay:   return localized("Sleep Display")
            case .screenSaver:    return localized("Start Screen Saver")
            case .toggleDarkMode: return localized("Toggle Dark Mode")
            case .emptyBin:       return localized("Empty Bin")
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
            }
        }

        /// An action whose title or a keyword starts with the query, from
        /// three letters: two would put "Sleep" above Slack for "sl".
        static func matching(_ query: String) -> [Action] {
            let q = query.lowercased()
            guard q.count >= 3 else { return [] }
            return allCases.filter { action in
                ([action.title.lowercased()] + action.keywords).contains { $0.hasPrefix(q) }
            }
        }
    }
}
