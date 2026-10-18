import Foundation
import os

/// Roost's log.
///
/// `os.Logger`, which is what macOS actually wants: the messages land in the
/// unified log, survive a crash, and can be read back with `log show` without
/// the app having written a file of its own. What this replaces kept its own
/// rotating file in Application Support, with a queue and a formatter, to do
/// a worse version of that.
///
/// Three levels, because three is what the call sites used. `debug` is
/// compiled out of release builds by the system rather than by a flag here.
enum Log {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier
                                       ?? "com.sagar.roost", category: "Roost")

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
