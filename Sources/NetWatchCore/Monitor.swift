import Foundation
import Network

/// Event-driven sampler. It sleeps on a coalescable timer, speeds up only while something is wrong,
/// slows down on battery, and takes an extra sample the moment the network path changes.
public final class Monitor: @unchecked Sendable { // all mutable state is touched only on `queue`
    public var onSample: ((Sample, TimeInterval) -> Void)?

    private let store: SampleStore
    private let prober: Prober
    private let baseInterval: TimeInterval
    private let fastInterval: TimeInterval
    private let queue = DispatchQueue(label: "netwatch.monitor")
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var calmSamples = 0

    public init(store: SampleStore, prober: Prober = Prober(), baseInterval: TimeInterval = 30, fastInterval: TimeInterval = 3) {
        self.store = store
        self.prober = prober
        self.baseInterval = baseInterval
        self.fastInterval = fastInterval
    }

    public func start() {
        store.prune(keepDays: 30)
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.queue.async { self?.schedule(after: 1) }
        }
        pathMonitor.start(queue: queue)
        queue.async { self.schedule(after: 0) }
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets the system batch this wake-up with others instead of waking the CPU just for us.
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(max(200, Int(delay * 100))))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        Task {
            let s = await prober.sample()
            queue.async { self.handle(s) }
        }
    }

    private func handle(_ s: Sample) {
        store.append(s)
        calmSamples = s.verdict == .ok ? calmSamples + 1 : 0
        let next: TimeInterval
        if calmSamples < 3 {
            next = fastInterval
        } else {
            next = SystemInfo.onBattery() ? baseInterval * 2 : baseInterval
        }
        busy = false
        schedule(after: next)
        onSample?(s, next)
    }
}
