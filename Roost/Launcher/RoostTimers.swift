import AppKit

/// Timers started from the search panel: "timer 10m tea".
///
/// Named `RoostTimers` because `Timer` is Foundation's. Each one is a
/// wall-clock deadline, like Keep awake's, so a ten-minute timer started at
/// two ends at ten past whether or not the lid was shut in between; and when
/// it ends it says so three ways -- a notification, a sound and a message on
/// screen -- because notifications may be switched off for Roost, and a timer
/// that ends in silence is no timer.
///
/// Not kept across a quit. A timer is for the next few minutes; one that
/// went off the morning after a restart would be about nothing anybody
/// remembers.
final class RoostTimers {

    static let shared = RoostTimers()

    struct Running: Equatable {
        let id: UUID
        let label: String?
        let endsAt: Date
    }

    private(set) var running: [Running] = []
    private var work: [UUID: DispatchWorkItem] = [:]
    /// Called when one ends, instead of the notification -- for the tests.
    var onFinish: ((Running) -> Void)?

    private init() {}

    @discardableResult
    func start(_ seconds: TimeInterval, label: String?) -> Running {
        let timer = Running(id: UUID(), label: label, endsAt: Date().addingTimeInterval(seconds))
        let item = DispatchWorkItem { [weak self] in self?.finish(timer.id) }
        work[timer.id] = item
        running.append(timer)
        running.sort { $0.endsAt < $1.endsAt }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: item)
        return timer
    }

    func cancel(_ id: UUID) {
        work.removeValue(forKey: id)?.cancel()
        running.removeAll { $0.id == id }
    }

    func timer(_ id: UUID) -> Running? { running.first { $0.id == id } }

    private func finish(_ id: UUID) {
        guard let timer = timer(id) else { return }
        work[id] = nil
        running.removeAll { $0.id == id }
        if let onFinish { onFinish(timer); return }

        let title = timer.label.map { localized("Timer done: %0", $0) } ?? localized("Timer done")
        Notice.post(title: title)
        NSSound(named: "Glass")?.play()
        Notify.show(title, symbol: "timer", for: 5)
    }

    /// A row's words for a running timer: "tea, ends at 14:30".
    static func describe(_ timer: Running) -> String {
        let end = KeepAwake.time(timer.endsAt)
        return timer.label.map { localized("%0, ends at %1", $0, end) } ?? localized("Ends at %0", end)
    }
}
