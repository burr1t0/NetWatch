import Foundation
import WidgetKit
import NetWatchCore

/// WidgetKit refreshes widgets on its own budget, which is far too slow for a live status.
/// This watches the sample log, asks for a reload when the verdict changes (and at most once a minute otherwise),
/// and feeds the same samples to the notifier.
final class WidgetRefresher: ObservableObject {
    @Published private(set) var snapshot = WidgetSnapshot.make(samples: [])

    private let store = SampleStore()
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
        notifier.evaluate(recent)
        if windowVisible { publishSnapshot() }
    }

    private func publishSnapshot() {
        let now = Date()
        let snap = WidgetSnapshot.make(samples: store.load(since: now.addingTimeInterval(-86_400)), now: now)
        DispatchQueue.main.async { self.snapshot = snap }
    }
}
