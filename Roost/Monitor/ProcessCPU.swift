import AppKit

/// The processes using the most processor time.
///
/// This used to spawn `/bin/ps`, on the stated reasoning that walking every
/// pid ourselves would be the expensive option. Measured, it is the other
/// way round by two orders of magnitude: **98 ms** to fork, exec and parse
/// `ps`, against **0.8 ms** to sweep all 447 processes with
/// `proc_pidinfo`. At one refresh a second that was about 10% of a core for
/// as long as the popup stayed open -- which is how Roost came to be the
/// top entry in its own list.
///
/// The reading is also better. `ps` reports a decaying average since the
/// process launched; this is a true rate, the CPU time a process actually
/// used between two samples.
///
/// Percentages are shares of **one** core, the way `ps` and `top` report
/// them -- a process can read 150% on an 8-core machine. That is not a bug
/// and the popup says "of one core" so nobody has to guess.
enum ProcessCPU {

    struct Entry: Identifiable {
        let pid: Int32
        let name: String
        /// Percent of a single core.
        let usage: Double
        var id: Int32 { pid }
    }

    private static let queue = DispatchQueue(label: "com.sagar.roost.cpu.processes",
                                             qos: .utility)
    private static var running = false

    static func top(_ limit: Int = 8, completion: @escaping ([Entry]) -> Void) {
        guard !running else { return }
        running = true

        queue.async {
            let entries = read(limit)
            DispatchQueue.main.async {
                running = false
                completion(entries)
            }
        }
    }

    /// Mach absolute time units are nanoseconds on Intel and 1/24 MHz
    /// ticks on Apple silicon. Read raw, every process on an M-series Mac
    /// would appear to use about forty times less than it does.
    private static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()

    private static var previous: [pid_t: UInt64] = [:]
    private static var previousAt: Date?

    /// Percent of one core between two readings of a process's CPU time.
    ///
    /// nil rather than zero when the answer cannot be trusted: no time has
    /// passed, or the counter went backwards, which means the pid was reused
    /// by a different process between samples.
    static func percent(before: UInt64, after: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, after >= before else { return nil }
        return Double(after - before) / 1_000_000_000 / elapsed * 100
    }

    /// Every process's CPU time now, in nanoseconds.
    private static func sweep() -> [pid_t: UInt64] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var times: [pid_t: UInt64] = [:]
        times.reserveCapacity(Int(max(0, filled)))
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(max(0, Int(filled))) where pid > 0 {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let ticks = info.pti_total_user + info.pti_total_system
            times[pid] = ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
        }
        return times
    }

    /// The executable's own name, which is what `ps -c comm` printed.
    ///
    /// Asked only for the handful of processes that made the list: it is a
    /// syscall each, and resolving all 447 would undo the saving.
    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }

    private static func read(_ limit: Int) -> [Entry] {
        let now = Date()
        let current = sweep()
        let before = previous
        let since = previousAt
        previous = current
        previousAt = now

        // The first refresh has nothing to compare against. One tick later
        // there is a real rate, which is better than showing an average
        // since boot for a second.
        guard let since else { return [] }
        let elapsed = now.timeIntervalSince(since)
        // A baseline a minute old is from before the popup was last shut, or
        // before the Mac slept: the first list on reopening was an average
        // over all of that. A fresh baseline now, and a real rate next tick,
        // which is what `ProcessNetwork` already did.
        guard elapsed < 60 else { return [] }

        let rates: [(pid: pid_t, usage: Double)] = current.compactMap { pid, after in
            guard let was = before[pid],
                  let usage = percent(before: was, after: after, elapsed: elapsed)
            else { return nil }
            return (pid, usage)
        }

        return rates
            .sorted { $0.usage != $1.usage ? $0.usage > $1.usage : $0.pid < $1.pid }
            .prefix(limit)
            .compactMap { entry in
                name(of: entry.pid).map { Entry(pid: entry.pid, name: $0, usage: entry.usage) }
            }
    }

}
