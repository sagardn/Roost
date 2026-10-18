import AppKit

/// Samples the system on a timer and keeps a short history, so the menu can
/// draw charts rather than only a single instantaneous number.
///
/// Rates need a previous sample to subtract from, so this has to run even
/// while the menu is closed. It is one timer doing a handful of syscalls, and
/// it can be switched off entirely from the menu.
final class Monitor {
    static let shared = Monitor()

    struct Sample {
        var cpu: Double = 0
        var memory: Double = 0
        var rx: Double = 0
        var tx: Double = 0
        var temperature: Double?
        var diskPercent: Double?
    }

    private(set) var latest = Sample()
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    /// Kept apart, not summed, so the chart can mirror download against
    /// upload the way the old one does.
    private(set) var rxHistory: [Double] = []
    private(set) var txHistory: [Double] = []
    /// Bytes moved since Roost started, for the network submenu.
    private(set) var sessionRx: UInt64 = 0
    private(set) var sessionTx: UInt64 = 0

    private let historyLength = 60          // 2s apart -> two minutes
    private let interval: TimeInterval = 2
    private var timer: Timer?

    /// Temperature costs far more than the other readings (it walks 39 HID
    /// services), so it is sampled every fifth tick rather than every one.
    private var tick = 0

    /// Called after every sample, on the main thread, so an open menu can
    /// redraw instead of showing whatever was true when it opened.
    var onSample: (() -> Void)?

    private init() {}

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        _ = Readings.cpuUsage()          // prime the deltas
        _ = Readings.network()
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer.tolerance = 0.5               // let the OS coalesce it
        // .common, not the default mode: an open NSMenu runs its own tracking
        // loop, and a default-mode timer does not fire inside it -- which is
        // exactly when the readings are being looked at.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        tick += 1

        if let cpu = Readings.cpuUsage() {
            latest.cpu = cpu
            push(&cpuHistory, cpu)
        }
        if let memory = Readings.memory() {
            latest.memory = memory.percent
            push(&memoryHistory, memory.percent)
        }
        if let network = Readings.network() {
            latest.rx = network.rxPerSecond
            latest.tx = network.txPerSecond
            push(&rxHistory, network.rxPerSecond)
            push(&txHistory, network.txPerSecond)
            sessionRx += UInt64(max(0, network.rxPerSecond * interval))
            sessionTx += UInt64(max(0, network.txPerSecond * interval))
        }
        if tick % 5 == 1, Temperature.isAvailable {
            latest.temperature = Temperature.cpu()
        }
        // Disk usage moves in minutes, not seconds, and the volume lookup is
        // the most expensive reading here after temperature.
        if tick % 15 == 1 {
            latest.diskPercent = Readings.disk()?.percent
        }

        onSample?()
    }

    private func push(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > historyLength { buffer.removeFirst(buffer.count - historyLength) }
    }
}
