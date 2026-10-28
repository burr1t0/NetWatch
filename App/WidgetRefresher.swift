import Foundation
import WidgetKit
import NetWatchCore

/// WidgetKit refreshes widgets on its own budget, which is far too slow for a live status.
/// This watches the sample log, asks for a reload when the verdict changes (and at most once a minute otherwise),
/// and feeds the same samples to the notifier.
final class WidgetRefresher: ObservableObject {
    @Published private(set) var snapshot = WidgetSnapshot.make(samples: [])

    private let store = SampleStore()
    private let registry = NetworkRegistry()
    private let rollups = RollupStore()
    private var range: StatsRange = .hour
    private let notifier: ProblemNotifier
    private let queue = DispatchQueue(label: "netwatch.refresher")
    private var timer: DispatchSourceTimer?
    private var lastVerdict: Verdict?
    private var lastReload = Date.distantPast
    private var windowVisible = false

    init(notifier: ProblemNotifier) {
        self.notifier = notifier
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 20, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func setWindowVisible(_ visible: Bool) {
        queue.async {
            self.windowVisible = visible
            if visible { self.publishSnapshot() }
        }
    }

    /// Period shown in the window's preview. The widget keeps its own choice.
    func setRange(_ newRange: StatsRange) {
        queue.async {
            self.range = newRange
            self.publishSnapshot()
        }
    }

    /// Gives the network the Mac is on now a name of the user's choosing and refreshes the widget with it.
    func renameCurrentNetwork(to name: String) {
        queue.async {
            guard let id = self.snapshot.networkID else { return }
            self.registry.rename(id: id, to: name)
            WidgetCenter.shared.reloadAllTimelines()
            self.publishSnapshot()
        }
    }

    func reloadNow() {
        queue.async {
            WidgetCenter.shared.reloadAllTimelines()
            self.lastReload = Date()
            self.publishSnapshot()
        }
    }

    private func tick() {
        let now = Date()
        // Half an hour is enough for both the verdict and incident detection; the full day is decoded only for the window.
        let recent = store.load(since: now.addingTimeInterval(-1800))
        guard let last = recent.last else { return }
        if last.verdict != lastVerdict || now.timeIntervalSince(lastReload) >= 60 {
            WidgetCenter.shared.reloadAllTimelines()
            lastReload = now
            lastVerdict = last.verdict
        }
        notifier.evaluate(recent, networks: registry.all())
        if windowVisible { publishSnapshot() }
    }

    private func publishSnapshot() {
        let now = Date()
        let samples = store.load(since: now.addingTimeInterval(-86_400))
        let networks = registry.all()
        var longRollups: [Rollup] = []
        if range != .hour {
            let stored = rollups.load(since: now.addingTimeInterval(-range.duration - 3600))
            longRollups = Rollups.merge(stored, with: Rollups.fresh(samples: samples, now: now, known: networks), keepSince: .distantPast)
        }
        let snap = WidgetSnapshot.make(samples: samples, now: now, networks: networks, range: range, rollups: longRollups)
        DispatchQueue.main.async { self.snapshot = snap }
    }
}
