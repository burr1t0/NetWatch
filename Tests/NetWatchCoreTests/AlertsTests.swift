import XCTest
@testable import NetWatchCore

final class AlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func sample(_ secondsAgo: TimeInterval, _ verdict: Verdict = .ok, gwMs: Double = 4, burst: [Int]? = nil, link: LinkStats? = nil) -> Sample {
        let good = Probe(sent: 3, received: 3, avgMs: 13, maxMs: 14)
        var s = Sample(t: now.addingTimeInterval(-secondsAgo), iface: "en0", gateway: "192.168.0.1",
                       gw: Probe(sent: 3, received: 3, avgMs: gwMs, maxMs: gwMs), direct: good, direct2: good,
                       dnsServer: "1.1.1.1", dnsMs: 20, tcpDirectMs: 14, httpMs: 100)
        s.verdict = verdict
        s.gwBurst = burst
        s.link = link
        s.system = link == nil ? nil : SystemStats(load1: 1, cores: 8)
        return s
    }

    /// Non-OK samples every 10 s from `from` seconds ago until `to` seconds ago, then OK ones up to now.
    private func episode(from: TimeInterval, to: TimeInterval, verdict: Verdict = .degraded, gwMs: Double = 120) -> [Sample] {
        var out: [Sample] = []
        var t = from
        while t >= to { out.append(sample(t, verdict, gwMs: gwMs)); t -= 10 }
        while t >= 0 { out.append(sample(t)); t -= 10 }
        return out
    }

    func testShortProblemStaysQuiet() {
        var state = AlertState()
        XCTAssertNil(Alerts.next(samples: episode(from: 40, to: 0), now: now, state: &state))
    }

    func testProblemThatHasJustClearedIsNotAnnounced() {
        var state = AlertState()
        // 100 s of trouble that ended 5 s ago: the incident still counts as ongoing, but the network is fine now.
        var samples = episode(from: 105, to: 10)
        samples.append(sample(0))
        XCTAssertNil(Alerts.next(samples: samples, now: now, state: &state))
        XCTAssertNil(state.notifiedSince)
    }

    func testLongProblemAlertsOnce() {
        var state = AlertState()
        let samples = episode(from: 100, to: 0)
        let first = Alerts.next(samples: samples, now: now, state: &state)
        XCTAssertEqual(first?.kind, .problem)
        XCTAssertTrue(first?.title.contains("Нестабильное соединение") ?? false, first?.title ?? "")
        XCTAssertNil(Alerts.next(samples: samples, now: now.addingTimeInterval(5), state: &state), "same incident must not alert twice")
    }

    func testRecoveryIsAnnouncedOnceAfterAProblemAlert() {
        var state = AlertState()
        _ = Alerts.next(samples: episode(from: 100, to: 0), now: now, state: &state)

        // 200 s later the network has been fine for a while.
        let later = now.addingTimeInterval(200)
        var samples = episode(from: 100, to: 0)
        for s in stride(from: 190.0, through: 0.0, by: -10.0) { samples.append(sample(s - 200)) }
        let recovered = Alerts.next(samples: samples, now: later, state: &state)
        XCTAssertEqual(recovered?.kind, .recovered)
        XCTAssertNil(Alerts.next(samples: samples, now: later.addingTimeInterval(10), state: &state))
    }

    func testNoRecoveryMessageIfNobodyWasWarned() {
        var state = AlertState()
        XCTAssertNil(Alerts.next(samples: [sample(5), sample(15), sample(25)], now: now, state: &state))
    }

    func testStaleDataIsSilent() {
        var state = AlertState()
        XCTAssertNil(Alerts.next(samples: [sample(900, .degraded), sample(890, .degraded), sample(800, .degraded)], now: now, state: &state))
    }

    func testFlappingNetworkIsRateLimited() {
        var state = AlertState(notifiedSince: nil, lastProblemAlert: now.addingTimeInterval(-60))
        XCTAssertNil(Alerts.next(samples: episode(from: 100, to: 0), now: now, state: &state))
    }

    func testAlertNamesTheLikelyCause() {
        var samples: [Sample] = []
        let burst = [3, 119, 3, 138, 3, 144, 3, 134, 3, 125, 4, 153, 4, 146, 22, 131, 4, 4, 6, 4]
        for t in stride(from: 100.0, through: 0.0, by: -10.0) {
            samples.append(sample(t, .degraded, gwMs: 120, burst: burst, link: LinkStats(rxBps: 3_000, txBps: 2_000, awdlBytes: 90_000)))
        }
        var state = AlertState()
        let alert = Alerts.next(samples: samples, now: now, state: &state)
        XCTAssertTrue(alert?.body.contains("Вероятная причина") ?? false, alert?.body ?? "")
        XCTAssertTrue(alert?.body.contains("AWDL") ?? false, alert?.body ?? "")
    }
}
