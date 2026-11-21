import AppKit
import Darwin

/// Says when one app keeps taking more memory: "Safari keeps using more
/// memory -- 6.2 GB, up 2.1 GB in 47 minutes."
///
/// The runaway-CPU alert's companion, for the slow failure it cannot see. A
/// leaking app is quiet on the processor and grows by a few megabytes a
/// minute until the whole Mac is swapping, and by then the Memory page only
/// shows that memory is short, not who took it. Nothing on the Mac warns
/// about the app while there is still time to quit it gracefully.
///
/// Measured by footprint, the figure Activity Monitor's Memory column shows,
/// summed over each app's processes -- a browser's tabs are its helpers.
final class MemoryGrowth {

    static let shared = MemoryGrowth()

    /// Once a minute: a leak is measured in tens of minutes, and a walk of
    /// every process is not free.
    static let interval: TimeInterval = 60

    static var isEnabled: Bool {
        get { Preferences.shared.bool("MemoryGrowth_enabled", default: true) }
        set {
            Preferences.shared.set("MemoryGrowth_enabled", newValue)
            newValue ? shared.start() : shared.stop()
        }
    }

    private var timer: Timer?
    private var detector = Detector()
    private let queue = DispatchQueue(label: "com.sagar.roost.memorygrowth", qos: .utility)

    private init() {}

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        RunawayApps.registerCategory()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { [self] in detector = Detector() }
    }

    private func tick() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let apps = Self.footprintByApp()
            let usage = apps.mapValues(\.bytes)
            for found in self.detector.observe(usage, at: now) {
                guard let app = apps[found.key] else { continue }
                DispatchQueue.main.async { Self.alert(app, found) }
            }
        }
    }

    // MARK: The decision

    /// Which apps have grown enough to be worth a word. Pure, so it can be fed
    /// numbers written down.
    ///
    /// All four, together:
    /// - at least `minimumSize` now -- a 300 MB app doubling is not news;
    /// - at least `growth` more than its smallest in the last hour;
    /// - at least half as much again as that smallest -- an app at 20 GB
    ///   that wobbles by a gigabyte is not growing, it is large;
    /// - at least `history` of readings, so an app that has just launched
    ///   and is loading is not "growing", it is starting.
    ///
    /// Said once. It is said again only after the app has come back below
    /// three quarters of the size it was reported at, or has quit.
    struct Detector {
        static let window: TimeInterval = 3600
        static let history: TimeInterval = 1800
        static let minimumSize: UInt64 = 2 << 30
        static let growth: UInt64 = 1 << 30

        struct Found: Equatable {
            let key: String
            let bytes: UInt64
            let grownBy: UInt64
            let minutes: Int
        }

        private(set) var samples: [String: [(at: TimeInterval, bytes: UInt64)]] = [:]
        private(set) var reported: [String: UInt64] = [:]

        mutating func observe(_ usage: [String: UInt64], at now: TimeInterval) -> [Found] {
            var found: [Found] = []
            for (key, bytes) in usage {
                var list = (samples[key] ?? []).filter { now - $0.at <= Self.window }
                list.append((now, bytes))
                samples[key] = list

                if let at = reported[key] {
                    if bytes < at / 4 * 3 { reported[key] = nil } else { continue }
                }
                guard let oldest = list.first?.at, now - oldest >= Self.history,
                      let low = list.min(by: { $0.bytes < $1.bytes }),
                      bytes >= Self.minimumSize, bytes >= low.bytes + Self.growth,
                      bytes >= low.bytes + low.bytes / 2 else { continue }
                reported[key] = bytes
                found.append(Found(key: key, bytes: bytes, grownBy: bytes - low.bytes,
                                   minutes: Int(((now - low.at) / 60).rounded())))
            }
            // Quit: forgotten, so a relaunch starts with a clean history.
            for key in samples.keys where usage[key] == nil {
                samples[key] = nil
                reported[key] = nil
            }
            return found.sorted { $0.key < $1.key }
        }
    }

    // MARK: Reading the kernel

    struct App {
        let name: String
        let bundle: URL?
        let bytes: UInt64
    }

    /// Each app's footprint, helpers folded in, keyed as the runaway alert
    /// keys them: the bundle's path, or the process name for a tool.
    static func footprintByApp() -> [String: App] {
        let own = getpid()
        var apps: [String: App] = [:]
        for pid in RunawayApps.allPIDs() where pid > 0 && pid != own {
            guard let path = RunawayApps.executablePath(pid), !RunawayApps.isSystem(path),
                  let bytes = footprint(pid) else { continue }
            let owner = RunawayApps.owner(of: path)
            let key = owner.bundle?.path ?? owner.name
            apps[key] = App(name: owner.name, bundle: owner.bundle,
                            bytes: (apps[key]?.bytes ?? 0) + bytes)
        }
        return apps
    }

    /// `ri_phys_footprint`: what Activity Monitor's Memory column reports.
    /// Resident size counts shared pages once per process, so a browser
    /// summed by resident size looked several times its real weight.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    // MARK: The alert

    private static func alert(_ app: App, _ found: Detector.Found) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(found.bytes), countStyle: .memory)
        let grown = ByteCountFormatter.string(fromByteCount: Int64(found.grownBy), countStyle: .memory)
        let canQuit = app.bundle.map { url in
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
        } ?? false
        RunawayApps.notify(
            id: "memorygrowth-\(app.name)",
            title: localized("%0 keeps using more memory", app.name),
            body: localized("Now %0, up %1 in %2 minutes. Quitting and reopening it gives the memory back.",
                            size, grown, String(found.minutes)),
            quitting: canQuit ? app.bundle : nil)
    }
}
