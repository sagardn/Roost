import Foundation

/// Per-process network throughput -- the "Top processes" table.
///
/// macOS publishes no API for this. The kernel accounts network bytes per
/// process, but the only thing allowed to read that accounting without a
/// kernel extension is `nettop`, which ships with the system. So this shells
/// out to it, one short snapshot at a time, and turns the cumulative byte
/// counts into rates by subtracting the previous snapshot.
///
/// It is the one reader here that spawns a process, so it runs on its own
/// queue, never on the sampling tick, and skips a round entirely if the last
/// one has not finished.
enum ProcessNetwork {

    struct Entry: Identifiable {
        let pid: Int32
        let name: String
        /// Bytes per second since the previous snapshot.
        let download: Double
        let upload: Double

        var id: Int32 { pid }
        var total: Double { download + upload }
    }

    /// Internal rather than private so the parser can be exercised directly.
    struct Snapshot { var received: UInt64; var sent: UInt64 }

    private static let queue = DispatchQueue(label: "com.sagar.roost.network.processes",
                                             qos: .utility)
    private static var previous: [Int32: Snapshot] = [:]
    private static var previousAt = Date.distantPast
    private static var running = false

    /// Reads a snapshot and hands back the busiest processes, newest rates
    /// first. The first call after launch returns nothing: a rate needs two
    /// snapshots to exist.
    static func top(_ limit: Int = 8, completion: @escaping ([Entry]) -> Void) {
        guard !running else { return }
        running = true

        queue.async {
            let counts = read()
            let now = Date()

            let elapsed = now.timeIntervalSince(previousAt)
            var entries: [Entry] = []

            // A gap long enough to be a sleep makes the delta meaningless.
            if elapsed > 0, elapsed < 60, !previous.isEmpty {
                for (pid, current) in counts {
                    guard let last = previous[pid],
                          current.received >= last.received,
                          current.sent >= last.sent else { continue }
                    let download = Double(current.received - last.received) / elapsed
                    let upload = Double(current.sent - last.sent) / elapsed
                    guard download > 0 || upload > 0 else { continue }
                    entries.append(Entry(pid: pid,
                                         name: names[pid] ?? "\(pid)",
                                         download: download,
                                         upload: upload))
                }
            }

            previous = counts
            previousAt = now
            entries.sort { $0.total > $1.total }
            let top = Array(entries.prefix(limit))

            DispatchQueue.main.async {
                running = false
                completion(top)
            }
        }
    }

    /// Drop the history so the next pair of snapshots starts clean -- used
    /// when the popup closes, so a reopen does not report a rate averaged
    /// over the minutes it spent shut.
    static func reset() {
        queue.async {
            previous = [:]
            previousAt = .distantPast
            names = [:]
        }
    }

    // MARK: - nettop

    private static var names: [Int32: String] = [:]

    /// `-P` aggregates by process rather than by connection, `-L 1` takes a
    /// single sample and exits, `-x` prints raw byte counts instead of
    /// human-readable ones, and `-J` picks just the two columns wanted.
    private static func read() -> [Int32: Snapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("Roost: nettop could not be run: \(error)")
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// Lines look like `io.tailscale.ip.4821,12345,678,` -- the process name
    /// can itself contain dots, so the pid is split off the end rather than
    /// the name off the front.
    static func parse(_ text: String) -> [Int32: Snapshot] {
        var counts: [Int32: Snapshot] = [:]

        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            let token = String(fields[0])
            guard let dot = token.lastIndex(of: "."),
                  let pid = Int32(token[token.index(after: dot)...]),
                  let received = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let sent = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }

            let name = String(token[..<dot])
            guard !name.isEmpty else { continue }

            names[pid] = name
            // nettop can list a process more than once; the counts add up.
            let existing = counts[pid]
            counts[pid] = Snapshot(received: (existing?.received ?? 0) + received,
                                   sent: (existing?.sent ?? 0) + sent)
        }
        return counts
    }
}
