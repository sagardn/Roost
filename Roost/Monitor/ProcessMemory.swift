import AppKit

/// The processes holding the most memory.
///
/// `ps` with `-m`, which sorts by resident size, rather than `top -o mem` --
/// which is what the module this replaces ran. Measured on an M2: `ps`
/// returns in 0.027s, `top -l 1` in 0.86s, and `top` spends most of that
/// second pinning a core, because it samples the whole system to produce one
/// listing. For a popup that refreshes while it is open, thirty times cheaper
/// is the difference between a reading and a cost.
///
/// The figure is **resident** memory: the physical pages a process has
/// in RAM now. Activity Monitor's "Memory" column is the phys_footprint,
/// which counts compressed and some shared pages differently, so the two
/// disagree by a few hundred megabytes on a busy machine. The popup says
/// "resident" rather than implying they are the same number.
enum ProcessMemory {

    struct Entry: Identifiable {
        let pid: Int32
        let name: String
        /// Bytes resident.
        let bytes: UInt64
        var id: Int32 { pid }
    }

    private static let queue = DispatchQueue(label: "com.sagar.roost.ram.processes",
                                             qos: .utility)
    private static var running = false

    static func top(_ limit: Int = 8, completion: @escaping ([Entry]) -> Void) {
        guard !running else { return }
        guard limit > 0 else {
            completion([])
            return
        }
        running = true

        queue.async {
            let entries = read(limit)
            DispatchQueue.main.async {
                running = false
                completion(entries)
            }
        }
    }

    /// `-A` every process, `-c` the executable name rather than the full
    /// argv, `-m` sorted by resident size.
    private static func read(_ limit: Int) -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,rss,comm", "-m"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("Roost: ps could not be run: \(error)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text, limit: limit)
    }

    /// Lines look like `  481 421760 Google Chrome`. RSS is in kilobytes, and
    /// the name is whatever is left after the two numeric columns, so it may
    /// contain spaces and brackets.
    static func parse(_ text: String, limit: Int) -> [Entry] {
        var entries: [Entry] = []

        for line in text.split(separator: "\n").dropFirst() {   // drop the header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let kilobytes = UInt64(parts[1]) else { continue }

            let name = parts[2].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, kilobytes > 0 else { continue }

            entries.append(Entry(pid: pid, name: name, bytes: kilobytes * 1024))
            if entries.count >= limit { break }   // already sorted by -m
        }
        return entries
    }
}
