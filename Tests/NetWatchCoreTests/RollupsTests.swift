import XCTest
@testable import NetWatchCore

final class RollupsTests: XCTestCase {
    // 4_500_000 / 900 = 5000, so this instant sits exactly on a quarter-hour boundary.
    private let t0 = Date(timeIntervalSince1970: 4_500_000)
    private let home = NetworkKey(id: "aaaa0001", gateway: "192.168.0.1")
    private let campus = NetworkKey(id: "bbbb0002", gateway: "10.20.0.1")

    private func sample(_ t: TimeInterval, _ net: NetworkKey? = nil, verdict: Verdict = .ok, gwMs: Double = 4, rtt: Double = 13) -> Sample {
        let probe = Probe(sent: 3, received: 3, avgMs: rtt, maxMs: rtt)
        var s = Sample(t: t0.addingTimeInterval(t), iface: "en0", gateway: (net ?? home).gateway,
                       gw: Probe(sent: 3, received: 3, avgMs: gwMs, maxMs: gwMs), direct: probe, direct2: probe,
                       dnsServer: "1.1.1.1", dnsMs: 20, tcpDirectMs: 14, httpMs: 100, network: net ?? home)
        s.verdict = verdict
        return s
    }

    // MARK: Ranges

    func testRangesHaveTheExpectedSlots() {
        XCTAssertEqual(StatsRange.hour.bucketCount, 60)
        XCTAssertEqual(StatsRange.day.bucketCount, 96)
        XCTAssertEqual(StatsRange.week.bucketCount, 84)
    }

    // MARK: Building

    func testBuildGroupsByQuarterHourAndKeepsPeaks() {
        let samples = [sample(0), sample(30, gwMs: 90, rtt: 200), sample(60, verdict: .degraded),
                       sample(1000)] // 1000 s later: the next quarter hour
        let rollups = Rollups.build(samples, known: [])
        XCTAssertEqual(rollups.count, 2)
        XCTAssertEqual(rollups[0].start, t0)
        XCTAssertEqual(rollups[0].gwMax, 90)
        XCTAssertEqual(rollups[0].rttMax, 200)
        XCTAssertEqual(rollups[0].worst, .degraded)
        // Each sample stands for the time until the next one, but a gap is capped at 120 s so that sleep is not counted as observation.
        XCTAssertEqual(rollups[0].seconds, 30 + 30 + 120, accuracy: 0.001)
        XCTAssertEqual(rollups[1].worst, .ok)
    }

    func testNetworksAreNeverMixedInOneBucket() {
        let rollups = Rollups.build([sample(0, home), sample(30, campus)], known: [])
        XCTAssertEqual(Set(rollups.compactMap(\.network)), [home.id, campus.id])
        XCTAssertEqual(rollups.count, 2)
    }

    func testFreshIgnoresAHalfFilledFirstBucket() {
        // `now` is 2 h after t0 plus 5 minutes; the window starts at t0 + 5 min, inside a quarter hour.
        let now = t0.addingTimeInterval(7200 + 300)
        let samples = [sample(7200 - 3600 + 600), sample(7200 + 100)]
        let fresh = Rollups.fresh(samples: samples, now: now, known: [], window: 7200)
        XCTAssertTrue(fresh.allSatisfy { $0.start >= t0.addingTimeInterval(900) }, "the cut first bucket must not be reported")
    }

    // MARK: Merging

    func testMergeReplacesTheSameBucketAndDropsOldOnes() {
        let old = [Rollup(start: t0, network: "a", seconds: 100, okSeconds: 100),
                   Rollup(start: t0.addingTimeInterval(900), network: "a", seconds: 50, okSeconds: 50),
                   Rollup(start: t0.addingTimeInterval(-90_000), network: "a", seconds: 10, okSeconds: 10)]
        let new = [Rollup(start: t0.addingTimeInterval(900), network: "a", seconds: 900, okSeconds: 800)]
        let merged = Rollups.merge(old, with: new, keepSince: t0.addingTimeInterval(-3600))
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.last?.seconds, 900)
    }

    // MARK: Incidents over a long range

    func testIncidentsAreRunsOfBadQuarterHours() {
        func bad(_ q: Int, _ v: Verdict = .degraded) -> Rollup {
            Rollup(start: t0.addingTimeInterval(Double(q) * 900), network: "a", seconds: 900, okSeconds: 600, worst: v)
        }
        func good(_ q: Int) -> Rollup { Rollup(start: t0.addingTimeInterval(Double(q) * 900), network: "a", seconds: 900, okSeconds: 900) }
        // bad, bad, one good quarter, bad (still the same run), then a long quiet stretch, then another problem.
        let rollups = [bad(0), bad(1, .dns), good(2), bad(3), good(4), good(5), good(6), bad(10, .isp)]
        let incidents = Rollups.incidents(rollups)
        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].verdict, .dns, "the worst verdict of the run wins")
        XCTAssertEqual(incidents[0].duration, 900, accuracy: 0.001, "300 s of trouble in each of three bad quarters")
        XCTAssertEqual(incidents[1].verdict, .isp)
    }

    // MARK: Store

    func testStoreMergesWithoutLosingNeighbouringBuckets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netwatch-rollups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = SampleStore(dir: dir)
        let rollups = RollupStore(dir: dir)

        let now = Date()
        let boundary = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.down) * 900)
        // One quarter hour ago and the one before it.
        for q in 1...2 {
            var s = sample(0)
            s.t = boundary.addingTimeInterval(-Double(q) * 900 + 60)
            samples.append(s)
        }
        rollups.update(store: samples, networks: [], from: boundary.addingTimeInterval(-1800))
        XCTAssertEqual(rollups.load(since: .distantPast).count, 2)

        // Updating only the newest quarter (from a time in the middle of it) must keep the older one and rebuild the newer fully.
        rollups.update(store: samples, networks: [], from: boundary.addingTimeInterval(-900 + 400))
        XCTAssertEqual(rollups.load(since: .distantPast).count, 2)
    }

    // MARK: Snapshot by range

    func testWeekSnapshotUsesRollupsOfTheCurrentNetworkOnly() {
        let now = t0.addingTimeInterval(7 * 86_400)
        let mine = (0..<100).map { Rollup(start: now.addingTimeInterval(-Double($0) * 900 - 900), network: home.id, seconds: 900, okSeconds: 900, gwMax: 5, rttMax: 15) }
        let other = [Rollup(start: now.addingTimeInterval(-2000), network: campus.id, seconds: 900, okSeconds: 0, worst: .isp)]
        let snap = WidgetSnapshot.make(samples: [sample(7 * 86_400 - 5)], now: now, range: .week, rollups: mine + other)

        XCTAssertEqual(snap.range, .week)
        XCTAssertEqual(snap.buckets.count, 84)
        XCTAssertEqual(snap.availability ?? 0, 1, accuracy: 0.0001, "the other network's outage is not counted")
        XCTAssertTrue(snap.buckets.contains { $0.rttMs == 15 })
        XCTAssertEqual(snap.incidents.count, 0)
    }

    func testDaySnapshotHasQuarterHourSlotsAndPeaks() {
        let now = t0.addingTimeInterval(86_400)
        let rollups = [Rollup(start: now.addingTimeInterval(-3600), network: home.id, seconds: 900, okSeconds: 300, gwMax: 120, rttMax: 240, worst: .degraded)]
        let snap = WidgetSnapshot.make(samples: [sample(86_400 - 5)], now: now, range: .day, rollups: rollups)
        XCTAssertEqual(snap.buckets.count, 96)
        XCTAssertEqual(snap.buckets.compactMap(\.rttMs).max(), 240)
        XCTAssertEqual(snap.availability ?? 0, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testHourSnapshotIsUnchangedByTheNewParameters() {
        let snap = WidgetSnapshot.make(samples: [sample(10)], now: t0.addingTimeInterval(20))
        XCTAssertEqual(snap.range, .hour)
        XCTAssertEqual(snap.buckets.count, WidgetSnapshot.bucketCount)
    }
}
