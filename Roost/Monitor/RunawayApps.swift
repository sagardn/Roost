import AppKit
import Darwin
import UserNotifications

/// Notices an app that has been working hard for minutes on end, and offers
/// to quit it.
///
/// The case it exists for was on screen while it was written: Shortcuts'
/// BackgroundShortcutRunner held 59% of a core for as long as anybody
/// watched, on a fanless Mac running at 96 °C, and nothing said so. A
/// threshold on the total load would not have fired -- the machine as a
/// whole was at a modest 30% -- so this watches each app on its own.
///
/// Sampled every 30 seconds from the kernel's own per-process CPU time
/// (`proc_pidinfo`), never by spawning `ps`: the popup's process list costs
/// a fifth of a core a run, and a watcher that never stops cannot afford it.
/// Helpers count towards their app -- Chrome's renderers are Chrome -- so
/// the alert names something a person recognises and can quit.
final class RunawayApps {

    static let shared = RunawayApps()

    static let interval: TimeInterval = 30

    private var timer: Timer?
    private var detector = Detector()
    /// Each process's CPU time at the last tick, by pid -- with the app it
    /// counted towards, so a pid reused by something else starts clean.
    private var previous: [Int32: ProcessTime] = [:]
    private var previousAt: TimeInterval?
    private let queue = DispatchQueue(label: "com.sagar.roost.runaway", qos: .utility)

    // MARK: Settings

    /// On by default: an alert nobody asked for is the cost, and it only
    /// arrives after five minutes of one app holding half a core.
    static var isEnabled: Bool {
        get { Preferences.shared.bool("Runaway_enabled", default: true) }
        set {
            Preferences.shared.set("Runaway_enabled", newValue)
            newValue ? shared.start() : shared.stop()
        }
    }

    /// Percent of one core, as Activity Monitor counts it: 100 is a core,
    /// 400 is four of them.
    static var threshold: Int {
        get { min(max(Preferences.shared.int("Runaway_threshold", default: 50), 10), 800) }
        set { Preferences.shared.set("Runaway_threshold", newValue) }
    }

    static var minutes: Int {
        get { min(max(Preferences.shared.int("Runaway_minutes", default: 5), 1), 60) }
        set { Preferences.shared.set("Runaway_minutes", newValue) }
    }

    // MARK: Running

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        Self.registerCategory()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // On the queue `tick()` works on: reset from here, it raced a tick
        // already in flight for the same two dictionaries.
        queue.async { [self] in
            previous.removeAll()
            previousAt = nil
            detector = Detector()
        }
    }

    private func tick() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let processes = Self.cpuByProcess()
            defer {
                self.previous = Dictionary(processes.map { ($0.pid, $0) },
                                           uniquingKeysWith: { first, _ in first })
                self.previousAt = now
            }
            guard let before = self.previousAt, now > before else { return }
            let usage = Self.usage(from: self.previous, to: processes, elapsed: now - before)
            var names: [String: (name: String, bundle: URL?)] = [:]
            for process in processes where usage[process.key] != nil {
                names[process.key] = (process.name, process.bundle)
            }

            let needed = max(1, Int((Double(Self.minutes) * 60 / Self.interval).rounded(.up)))
            let flagged = self.detector.observe(usage, threshold: Double(Self.threshold), samples: needed)
            for key in flagged {
                guard let info = names[key] else { continue }
                DispatchQueue.main.async {
                    Self.alert(name: info.name, bundle: info.bundle,
                               percent: usage[key] ?? 0, minutes: Self.minutes)
                }
            }
        }
    }

    // MARK: The decision

    /// Which apps have stayed at or above the threshold for long enough, and
    /// have not been reported for this stretch yet. Pure, so it can be fed
    /// numbers.
    struct Detector {
        /// Consecutive samples at or above the threshold, per app.
        private(set) var streak: [String: Int] = [:]
        /// Reported during the current stretch; cleared when the app calms.
        private(set) var reported: Set<String> = []

        mutating func observe(_ usage: [String: Double], threshold: Double, samples: Int) -> [String] {
            var flagged: [String] = []
            for (key, percent) in usage {
                if percent >= threshold {
                    let count = (streak[key] ?? 0) + 1
                    streak[key] = count
                    if count >= samples, !reported.contains(key) {
                        reported.insert(key)
                        flagged.append(key)
                    }
                } else {
                    streak[key] = 0
                    // Only well below the line counts as calm again, so an
                    // app hovering at the threshold is not reported every
                    // time it dips and rises.
                    if percent < threshold / 2 { reported.remove(key) }
                }
            }
            // Gone from the sample: quit, or nothing to say about it.
            for key in streak.keys where usage[key] == nil {
                streak[key] = nil
                reported.remove(key)
            }
            return flagged.sorted()
        }
    }

    // MARK: Reading the kernel

    struct AppTime {
        /// The app bundle's path, or the process name for a command-line tool.
        let key: String
        let name: String
        let bundle: URL?
        let cpuNanoseconds: UInt64
    }

    /// One process's CPU time so far, and the app it counts towards.
    struct ProcessTime {
        let pid: Int32
        /// The app bundle's path, or the process name for a command-line tool.
        let key: String
        let name: String
        let bundle: URL?
        let cpuNanoseconds: UInt64
    }

    /// Every process Roost may report on, with the app it belongs to.
    static func cpuByProcess() -> [ProcessTime] {
        let own = getpid()
        var processes: [ProcessTime] = []
        for pid in allPIDs() where pid > 0 && pid != own {
            guard let cpu = cpuTime(pid), let path = executablePath(pid),
                  !isSystem(path) else { continue }
            let owner = Self.owner(of: path)
            processes.append(ProcessTime(pid: pid, key: owner.bundle?.path ?? owner.name,
                                         name: owner.name, bundle: owner.bundle,
                                         cpuNanoseconds: cpu))
        }
        return processes
    }

    /// Per-app CPU time so far, helpers folded into their app.
    static func cpuByApp() -> [AppTime] {
        var totals: [String: AppTime] = [:]
        for process in cpuByProcess() {
            let sum = (totals[process.key]?.cpuNanoseconds ?? 0) + process.cpuNanoseconds
            totals[process.key] = AppTime(key: process.key, name: process.name,
                                          bundle: process.bundle, cpuNanoseconds: sum)
        }
        return Array(totals.values)
    }

    /// Percent of one core each app used between two readings.
    ///
    /// Differenced per process and then added up per app. It was the other
    /// way round -- each app's total, differenced -- and a helper exiting
    /// took its whole lifetime's CPU out of the total: the app's time went
    /// backwards, its sample was dropped, and the detector, seeing it gone,
    /// took it for quit and forgot it had already reported it. A browser
    /// held at 200% while tabs came and went was announced again every five
    /// minutes. An app is measured when any process of it was seen last time
    /// and is still running; a process new since then has no baseline yet
    /// and counts from the next reading.
    static func usage(from previous: [Int32: ProcessTime], to current: [ProcessTime],
                      elapsed: TimeInterval) -> [String: Double] {
        guard elapsed > 0 else { return [:] }
        var nanoseconds: [String: UInt64] = [:]
        for process in current {
            guard let before = previous[process.pid], before.key == process.key,
                  process.cpuNanoseconds >= before.cpuNanoseconds else { continue }
            nanoseconds[process.key, default: 0] += process.cpuNanoseconds - before.cpuNanoseconds
        }
        return nanoseconds.mapValues { Double($0) / 1e9 / elapsed * 100 }
    }

    /// The app an executable belongs to: the outermost `.app` in its path,
    /// so `Google Chrome.app/…/Google Chrome Helper (Renderer).app/…` is
    /// Google Chrome. A process outside any app is named by its file.
    ///
    /// Only when the executable is itself an app's -- sitting in some
    /// `<name>.app/Contents/MacOS/`. A toolchain binary merely *lives* inside
    /// an app: `Xcode.app/Contents/Developer/…/swift-frontend` is a compiler,
    /// usually run from a terminal, and folding it into Xcode produced
    /// "Xcode is working hard" with a Quit button that would close somebody's
    /// editor and leave the compile running. roost-06 found it, running this
    /// on real paths.
    static func owner(of path: String) -> (name: String, bundle: URL?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let isAppExecutable = parts.count >= 4 && parts[parts.count - 2] == "MacOS"
            && parts[parts.count - 3] == "Contents" && parts[parts.count - 4].hasSuffix(".app")
        if isAppExecutable, let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = parts[...index].joined(separator: "/")
            let name = String(parts[index].dropLast(4))
            return (name, URL(fileURLWithPath: bundlePath))
        }
        return (String(parts.last ?? Substring(path)), nil)
    }

    /// macOS's own processes. They are never reported: nothing a person can
    /// do will stop Spotlight indexing or StorageManagementService sizing
    /// the disk, so an alert about them is noise that teaches people to
    /// ignore the alert. Measured: StorageManagementService held half a core
    /// for ten samples in a row on an ordinary machine. The same rule drops
    /// Shortcuts' BackgroundShortcutRunner, the case that prompted this --
    /// accepted, because the alternative is a list of system services to
    /// make exceptions for, and that list is never finished.
    static func isSystem(_ path: String) -> Bool {
        // /usr/local is not Apple's: it is Homebrew's prefix on Intel, where
        // a runaway `node` lives -- the case this is for. So /usr is listed
        // by the directories Apple owns, never whole.
        ["/System/", "/Library/Apple/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/",
         "/bin/", "/sbin/"].contains { path.hasPrefix($0) }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(filled))))
    }

    /// User plus system time. `proc_pidinfo` reports it in Mach absolute
    /// time units, which are nanoseconds on Intel and 1/24 MHz ticks on
    /// Apple silicon -- read raw, every app on an M-series Mac would appear
    /// to use about 40 times less than it does.
    private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        return ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: The alert

    static let category = "roost.runaway"
    static let quitAction = "quit"

    private static func registerCategory() {
        let quit = UNNotificationAction(identifier: quitAction, title: localized("Quit"),
                                        options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.category, actions: [quit],
                                              intentIdentifiers: [], options: [])
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationCategories { existing in
            centre.setNotificationCategories(existing.filter { $0.identifier != Self.category }
                                                .union([category]))
        }
    }

    private static func alert(name: String, bundle: URL?, percent: Double, minutes: Int) {
        let canQuit = bundle.map { url in
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
        } ?? false
        let content = UNMutableNotificationContent()
        content.title = localized("%0 is working hard", name)
        content.body = localized("%0% CPU for %1 minutes.", String(Int(percent.rounded())), String(minutes))
            + (canQuit ? "" : " " + localized("Open Activity Monitor to see why."))
        content.sound = .default
        if canQuit, let bundle {
            content.categoryIdentifier = category
            content.userInfo = ["runawayBundle": bundle.path]
        }
        let request = UNNotificationRequest(identifier: "runaway-\(name)", content: content, trigger: nil)
        let centre = UNUserNotificationCenter.current()
        if centre.delegate == nil { centre.delegate = NSApp.delegate as? UNUserNotificationCenterDelegate }
        centre.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                centre.add(request)
            case .notDetermined:
                centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { centre.add(request) }
                }
            default:
                break
            }
        }
    }

    /// The Quit button. Asks the app to quit, the way ⌘Q does -- never a
    /// force quit from a notification, because a document with unsaved
    /// changes must still get to ask.
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == category else { return false }
        if response.actionIdentifier == quitAction,
           let path = content.userInfo["runawayBundle"] as? String {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL == url }.forEach { $0.terminate() }
        }
        return true
    }
}
