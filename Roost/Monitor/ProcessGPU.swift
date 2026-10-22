import Foundation
import IOKit

/// The processes using the most graphics processor time.
///
/// Read from the IORegistry, as `GPUStats` is. Every process that talks to
/// the GPU holds a user client under the accelerator, and that client
/// publishes two things: `IOUserClientCreator` -- "pid 421, WindowServer" --
/// and `AppUsage`, one dictionary per command queue with an
/// `accumulatedGPUTime` in nanoseconds. Two samples a second apart give each
/// process's share of the GPU over that second, the way `ProcessCPU` turns
/// CPU time into a rate.
///
/// Each figure is **GPU time**: how long that process's work occupied the
/// GPU, as a share of the interval. It is not a slice of the headline
/// `Device Utilization %`, and the two do not add up except at the ends.
/// Measured on an M2 with a Metal kernel run for a set share of every 100 ms,
/// two-second windows, the driver's figure averaged over twenty reads:
///
///     load        Device Utilization %   processes summed
///     idle               1.5                  4.2
///     30%               76                   37
///     70%               91                   83
///     constant          98                   99
///
/// The driver counts the GPU busy for any sampling period something ran in,
/// so a bursty load reads high; GPU time counts only the work. So the list
/// says "GPU time" over its column, and the ranking -- which app is using
/// the GPU most -- is the part that holds at every load.
enum ProcessGPU {

    struct Entry: Identifiable {
        let pid: Int32
        /// The name the driver recorded, which is the kernel's short process
        /// name: sixteen characters at most. `ProcessRow` resolves the full
        /// app name and icon from the pid, so this is only the fallback.
        let name: String
        /// Percent of the GPU's time between two samples.
        let usage: Double
        var id: Int32 { pid }
    }

    /// What a refresh found. Three answers, because the list has three
    /// different things to say and an empty array can only say one of them:
    /// the first sample, which has no rate yet, read as "nothing is using
    /// the GPU" beside a headline of 19%.
    enum Sample {
        /// One sample taken; the rate comes with the next.
        case measuring
        /// No client on this Mac reports GPU time -- an Intel or AMD driver,
        /// or a new chip that spells the key differently.
        case unreported
        /// The busiest, most first. Empty means nothing is using the GPU.
        case busiest([Entry])
    }

    private static let queue = DispatchQueue(label: "com.sagar.roost.gpu.processes",
                                             qos: .utility)
    private static var running = false

    /// The busiest `limit`, delivered on the main queue. `top(0)` reads
    /// nothing and forgets the last sample, so a popup opened again later
    /// does not compute a rate across the whole time it was closed.
    static func top(_ limit: Int = 6, completion: @escaping (Sample) -> Void) {
        guard !running else { return }
        running = true

        queue.async {
            let entries = limit > 0 ? read(limit) : forget()
            DispatchQueue.main.async {
                running = false
                completion(entries)
            }
        }
    }

    // MARK: - Pure

    /// The pid and name out of `IOUserClientCreator`: "pid 421, WindowServer".
    ///
    /// nil for anything else, rather than a guess. A kernel client reads
    /// "pid 0, kernel_task", and pid 0 is not a process anyone can quit, so
    /// it is refused here along with the malformed ones.
    static func creator(_ text: String) -> (pid: Int32, name: String)? {
        guard text.hasPrefix("pid ") else { return nil }
        let rest = text.dropFirst(4)
        let parts = rest.split(separator: ",", maxSplits: 1)
        guard let first = parts.first,
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (pid, name)
    }

    /// The spellings of a queue's GPU time. One is known, from Apple
    /// silicon M1 to M4; a list so that a driver which renames it is a
    /// one-line fix once `Tools/hardware-report.swift` shows the new name.
    static let timeKeys = ["accumulatedGPUTime"]

    /// The GPU time in one client's `AppUsage`, summed over its queues.
    ///
    /// nil when no queue carries the figure under any known spelling -- not
    /// zero, which would read as "idle" on a driver that simply does not say.
    /// A client with no queues at all has used no GPU, and that is a true 0.
    static func gpuTime(_ usage: [[String: Any]]) -> UInt64? {
        guard !usage.isEmpty else { return 0 }
        var total: UInt64 = 0
        var found = false
        for queue in usage {
            guard let value = timeKeys.lazy.compactMap({ queue[$0] as? NSNumber }).first else { continue }
            total &+= value.uint64Value
            found = true
        }
        return found ? total : nil
    }

    /// Percent of the GPU between two readings of a process's GPU time.
    ///
    /// nil when it cannot be trusted: no time passed, or the counter went
    /// backwards -- the client was closed and another opened in its place,
    /// or the pid was reused.
    static func percent(before: UInt64, after: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, after >= before else { return nil }
        return Double(after - before) / 1_000_000_000 / elapsed * 100
    }

    // MARK: - Reading

    private static var previous: [Int32: UInt64] = [:]
    private static var previousAt: Date?
    private static var names: [Int32: String] = [:]

    private static func forget() -> Sample {
        previous = [:]
        previousAt = nil
        return .measuring
    }

    private static func read(_ limit: Int) -> Sample {
        let now = Date()
        guard let current = sweep() else { return .unreported }
        let before = previous
        let since = previousAt
        previous = current
        previousAt = now

        // The first sample has nothing to compare against, and "measuring"
        // for a tick beats an average since boot.
        guard let since else { return .measuring }
        let elapsed = now.timeIntervalSince(since)
        // Stale for the same reason as `ProcessCPU`'s: the forget on closing
        // the popup is skipped when a read is in flight, and a sleep needs no
        // closing at all.
        guard elapsed < 60 else { return .measuring }

        let rates: [Entry] = current.compactMap { pid, after in
            guard let was = before[pid],
                  let usage = percent(before: was, after: after, elapsed: elapsed),
                  // Below a tenth of a percent rounds to 0.0% in the row, and
                  // a list of zeros says less than "nothing is using it".
                  usage >= 0.1 else { return nil }
            return Entry(pid: pid, name: names[pid] ?? "", usage: usage)
        }
        return .busiest(Array(rates
            .sorted { $0.usage != $1.usage ? $0.usage > $1.usage : $0.pid < $1.pid }
            .prefix(limit)))
    }

    /// Every client of every accelerator, summed per process.
    ///
    /// WindowServer alone holds several clients; a process's share is all
    /// of them together, which is what "this app is using the GPU" means.
    ///
    /// nil when not one client reported a time -- see `top`.
    private static func sweep() -> [Int32: UInt64]? {
        let found = census()
        return found.timed > 0 ? found.times : nil
    }

    /// How many GPU clients this Mac has, how many of them report GPU time,
    /// and the times themselves. Internal rather than private for
    /// `Tools/hardware-report.swift`, which prints the first two so a Mac
    /// whose driver spells the key differently says so in an issue.
    static func census() -> (clients: Int, timed: Int, times: [Int32: UInt64]) {
        var times: [Int32: UInt64] = [:]
        var clientCount = 0
        var timed = 0
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &accelerators) == KERN_SUCCESS else { return (0, 0, times) }
        defer { IOObjectRelease(accelerators) }

        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let (pid, name, time) = usage(of: client) {
                        clientCount += 1
                        if let time {
                            timed += 1
                            times[pid, default: 0] &+= time
                            names[pid] = name
                        }
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return (clientCount, timed, times)
    }

    /// The two properties wanted, read by name rather than copying the
    /// client's whole property table: it carries a dozen other keys, and
    /// this runs for every client every second the popup is open.
    private static func usage(of client: io_registry_entry_t) -> (Int32, String, UInt64?)? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(client, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        guard let text = property("IOUserClientCreator") as? String,
              let (pid, name) = creator(text),
              let queues = property("AppUsage") as? [[String: Any]] else { return nil }
        return (pid, name, gpuTime(queues))
    }
}
