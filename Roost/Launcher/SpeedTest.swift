import Foundation

/// The internet speed, measured by macOS's own `networkQuality`.
///
/// Apple's tool, shipped with macOS since Monterey, against Apple's own
/// servers: no third-party speed-test service learns anything, and nothing is
/// sent unless somebody asks for a test. It reports throughput both ways and
/// responsiveness -- how well the connection keeps up while it is busy,
/// which is what a video call feels, and which a plain "Mbps" number hides.
enum SpeedTest {

    struct Result: Equatable {
        /// Bits per second.
        let download: Double
        let upload: Double
        /// Apple's own grade, as the tool prints it: Low, Medium or High.
        let responsiveness: String?
    }

    /// Reads the tool's summary. Its plain output rather than `-c`'s JSON,
    /// because only the plain output carries the grade: the JSON gives round
    /// trips a minute, and Apple publishes no numbers for where Low becomes
    /// Medium -- a grade worked out here would be a guess dressed as Apple's.
    ///
    ///     Uplink capacity: 38.123 Mbps
    ///     Downlink capacity: 245.678 Mbps
    ///     Responsiveness: High (24.2 milliseconds | 2478 RPM)
    ///
    /// nil without both capacities, which is what a failed run prints.
    static func parse(_ text: String) -> Result? {
        func capacity(_ name: String) -> Double? {
            let pattern = name + #" capacity:\s*([0-9.]+)\s*(Gbps|Mbps|Kbps|bps)"#
            guard let match = try? NSRegularExpression(pattern: pattern)
                    .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let number = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
                  let unit = Range(match.range(at: 2), in: text).map({ String(text[$0]) })
            else { return nil }
            switch unit {
            case "Gbps": return number * 1e9
            case "Mbps": return number * 1e6
            case "Kbps": return number * 1e3
            default:     return number
            }
        }
        guard let down = capacity("Downlink"), let up = capacity("Uplink") else { return nil }
        var grade: String?
        if let match = try? NSRegularExpression(pattern: #"(?m)^\s*Responsiveness:\s*(Low|Medium|High)\b"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            grade = String(text[range])
        }
        return Result(download: down, upload: up, responsiveness: grade)
    }

    /// "↓ 245 Mbps  ↑ 38 Mbps · Responsiveness: High"
    static func describe(_ result: Result) -> String {
        func rate(_ bits: Double) -> String {
            bits >= 1_000_000_000 ? String(format: "%.1f Gbps", bits / 1e9)
                : bits >= 10_000_000 ? String(format: "%.0f Mbps", bits / 1e6)
                : String(format: "%.1f Mbps", bits / 1e6)
        }
        var line = "↓ \(rate(result.download))  ↑ \(rate(result.upload))"
        if let grade = result.responsiveness {
            // Spelt out so each word is a key the translations can see.
            let word: String
            switch grade {
            case "High":   word = localized("High")
            case "Medium": word = localized("Medium")
            default:       word = localized("Low")
            }
            line += " · " + localized("Responsiveness: %0", word)
        }
        return line
    }

    private static var running = false

    /// Runs a test off the main thread -- it takes ten to twenty seconds --
    /// and hands back the result, or nil if it failed, on main. A second
    /// request while one runs is ignored: two tests at once would each
    /// measure half the line.
    static func run(completion: @escaping (Result?) -> Void) {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            process.arguments = []
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var result: Result?
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = parse(String(bytes: data, encoding: .utf8) ?? "")
            } catch {
                Log.error("speed test: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                running = false
                completion(result)
            }
        }
    }
}
