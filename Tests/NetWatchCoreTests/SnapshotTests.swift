import XCTest
@testable import NetWatchCore

final class SnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func sample(_ secondsAgo: TimeInterval, _ verdict: Verdict = .ok, rtt: Double = 13) -> Sample {
        let good = Probe(sent: 3, received: 3, avgMs: rtt, maxMs: rtt)
        var s = Sample(t: now.addingTimeInterval(-secondsAgo), iface: "en0", gateway: "192.168.0.1",
                       gw: Probe(sent: 3, received: 3, avgMs: 4, maxMs: 5), direct: good, direct2: good,
                       dnsServer: "1.1.1.1", dnsMs: 20, tcpDirectMs: 14, httpMs: 100)
        s.verdict = verdict
        return s
    }

    func testFreshHealthySample() {
        let snap = WidgetSnapshot.make(samples: [sample(10)], now: now)
        XCTAssertFalse(snap.isStale)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.headline, "Всё в порядке")
        XCTAssertEqual(snap.buckets.count, WidgetSnapshot.bucketCount)
    }

    func testOldSampleIsStale() {
        let snap = WidgetSnapshot.make(samples: [sample(600)], now: now)
        XCTAssertTrue(snap.isStale)
        XCTAssertNil(snap.status)
        XCTAssertEqual(snap.headline, "Нет свежих данных")
    }

    func testNoSamples() {
        let snap = WidgetSnapshot.make(samples: [], now: now)
        XCTAssertTrue(snap.isStale)
        XCTAssertEqual(snap.headline, "Нет данных")
        XCTAssertNil(snap.availability)
    }

    func testBucketKeepsWorstVerdictAndPeakLatency() {
        // 125 s ago lands in minute 57 of the hour window, together with the sample 130 s ago.
        let snap = WidgetSnapshot.make(samples: [sample(130, .ok, rtt: 10), sample(125, .degraded, rtt: 90), sample(5)], now: now)
        let bucket = snap.buckets.first { $0.verdict == .degraded }
        XCTAssertEqual(bucket?.rttMs, 90)
        XCTAssertEqual(snap.buckets.last?.verdict, .ok)
    }

    func testAvailabilityIsTimeWeighted() {
        // 60 s of OK followed by 60 s of a problem state.
        let snap = WidgetSnapshot.make(samples: [sample(120), sample(60, .isp), sample(0, .ok)], now: now)
        XCTAssertEqual(snap.availability ?? 0, 0.6, accuracy: 0.25)
        XCTAssertLessThan(snap.availability ?? 1, 1)
    }

    func testIncidentsAreNewestFirst() {
        let samples = [sample(7200, .dns), sample(7190), sample(3600, .isp), sample(3590), sample(5)]
        let snap = WidgetSnapshot.make(samples: samples, now: now)
        XCTAssertEqual(snap.incidents.map(\.verdict), [.isp, .dns])
    }

    func testDegradedReasonIsSpelledOut() {
        var s = sample(5, .degraded)
        s.gw = Probe(sent: 3, received: 3, avgMs: 85, maxMs: 90)
        let snap = WidgetSnapshot.make(samples: [s], now: now)
        XCTAssertTrue(snap.detail.contains("роутер 85 мс"), snap.detail)
    }
}
