import AppKit
import Combine

/// The busiest processes, for the Dashboard's table.
///
/// The one place on the Dashboard that samples something of its own. Every
/// card above it reads what the menu bar tick already measured; there is no
/// such tick for processes, because the CPU and Memory modules only sample
/// them while their own popup is open.
///
/// So it samples, and the cost is kept down three ways. It runs only while
/// the Dashboard is on screen, every three seconds rather than every one --
/// a table that reshuffles itself every second cannot be read anyway -- and
/// it asks for the few rows it draws rather than the whole machine.
final class DashboardProcesses: ObservableObject {

    struct Row: Identifiable {
        let pid: Int32
        let name: String
        /// Percent of one core, the way the CPU popup reports it.
        let cpu: Double
        /// Bytes resident, or nil when this process is on the list for its
        /// processor use and nothing said what it holds.
        let memory: UInt64?

        var id: Int32 { pid }
    }

    /// Which column the table is ordered by.
    ///
    /// Stored, because a sort somebody chose and lost on the next launch is
    /// worse than one they cannot change. Processor use is the default: it
    /// is the question a monitor is opened to answer.
    enum Sort: String, CaseIterable {
        case cpu, memory, name

        var title: String {
            switch self {
            case .cpu:    return localized("Processor")
            case .memory: return localized("Memory")
            case .name:   return localized("Process")
            }
        }
    }

    @Published var sort: Sort {
        didSet {
            guard sort != oldValue else { return }
            Preferences.shared.set(Self.sortKey, sort.rawValue)
            rows = Self.ordered(rows, by: sort)
        }
    }

    private static let sortKey = "Dashboard_processSort"

    init() {
        let stored = Preferences.shared.string(Self.sortKey, default: Sort.cpu.rawValue)
        sort = Sort(rawValue: stored) ?? .cpu
    }

    @Published private(set) var rows: [Row] = []
    /// False until the first pair of samples has landed. The first CPU
    /// reading has nothing to difference against and is empty by design, so
    /// the table says it is measuring rather than showing an empty box.
    @Published private(set) var hasSampled = false

    /// Eight: enough to show what is actually busy, few enough that the
    /// table does not become the page.
    static let limit = 8

    private var timer: Timer?

    /// How many rows deep to look in each list. Wider than `limit` so a
    /// process that is heavy on memory but idle on processor still reaches
    /// the merge.
    static let depth = 20

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    private func start() {
        refresh()
        // Three seconds, and tolerant: this is a readout, not an alarm, and
        // letting macOS align the wake-up with others it already has is the
        // difference between a timer that costs something and one that does
        // not.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // Asked for more rows than are drawn, because sorting by memory or
        // by name has to choose from a wider field than "the eight busiest"
        // -- otherwise sorting by memory only reorders the busiest eight,
        // which is not what the column says it does.
        ProcessCPU.top(Self.depth) { [weak self] busy in
            guard let self else { return }
            let all = busy.map {
                Row(pid: $0.pid, name: $0.name, cpu: $0.usage, memory: Self.resident(of: $0.pid))
            }
            self.rows = Array(Self.ordered(all, by: self.sort).prefix(Self.limit))
            if !busy.isEmpty { self.hasSampled = true }
        }
    }

    /// Ordered by one column, with a stable tiebreak so rows do not swap
    /// places between refreshes when two processes read the same figure.
    static func ordered(_ rows: [Row], by sort: Sort) -> [Row] {
        switch sort {
        case .cpu:
            return rows.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }
        case .memory:
            // A process whose memory could not be read sorts last rather
            // than as zero: unknown is not small.
            return rows.sorted {
                let a = $0.memory, b = $1.memory
                if a == nil && b == nil { return $0.pid < $1.pid }
                guard let a else { return false }
                guard let b else { return true }
                return a != b ? a > b : $0.pid < $1.pid
            }
        case .name:
            return rows.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
            }
        }
    }

    /// What one process holds, asked of the kernel directly.
    ///
    /// `ProcessMemory` answers "which processes are the largest", which is a
    /// different question: matching its list against the busiest ones left
    /// most rows showing a dash, because a process can be busy without being
    /// big. Asking per pid is one syscall for each of the eight rows drawn,
    /// and every row gets a figure.
    ///
    /// nil when the process has gone between the two calls, which is normal
    /// and is why the row can still say "—".
    static func resident(of pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pti_resident_size)
    }

}
