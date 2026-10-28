import XCTest
@testable import NetWatchCore

final class CausesTests: XCTestCase {
    private let calmLink = LinkStats(rxBps: 20_000, txBps: 5_000)
    private let calmSystem = SystemStats(load1: 1.0, cores: 8)

    private func spike(link: LinkStats? = nil, system: SystemStats? = nil, burst: [Int]? = nil) -> Sample {
        Sample(iface: "en0", gateway: "192.168.0.1", gw: Probe(sent: 3, received: 3, avgMs: 120, maxMs: 200),
               verdict: .degraded, link: link, system: system, gwBurst: burst)
    }

    func testOnlyAboveThirtyMillisecondsIsASpike() {
        XCTAssertTrue(Causes.isLocalSpike(spike()))
        var calm = spike(); calm.gw = Probe(sent: 3, received: 3, avgMs: 5, maxMs: 6)
        XCTAssertFalse(Causes.isLocalSpike(calm))
    }

    func testHeavyOwnTrafficIsABlame() {
        let s = spike(link: LinkStats(rxBps: 5_000_000, txBps: 100_000), system: calmSystem)
        XCTAssertEqual(Causes.causes(for: s), [.ownTraffic])
    }

    func testAwdlTrafficIsABlame() {
        let s = spike(link: LinkStats(rxBps: 1_000, txBps: 1_000, awdlBytes: 250_000), system: calmSystem)
        XCTAssertEqual(Causes.causes(for: s), [.awdl])
    }

    func testPowerSavingAndLoad() {
        let s = spike(link: calmLink, system: SystemStats(load1: 9.5, cores: 8, thermal: 2, lowPower: false))
        XCTAssertEqual(Set(Causes.causes(for: s)), [.powerSaving, .cpuLoad])
    }

    func testNothingLocalMeansExternal() {
        XCTAssertEqual(Causes.causes(for: spike(link: calmLink, system: calmSystem)), [.external])
    }

    func testNoContextGivesNoCauses() {
        XCTAssertEqual(Causes.causes(for: spike()), [])
    }

    func testBurstPatterns() {
        XCTAssertEqual(Causes.burstPattern(Array(repeating: 120, count: 20)), .congestion)
        XCTAssertEqual(Causes.burstPattern([5, 5, 5, 220, 5, 5, 5, 5, 5, 190, 5, 5, 5, 5]), .bursts)
        XCTAssertNil(Causes.burstPattern(Array(repeating: 5, count: 20)))
        XCTAssertNil(Causes.burstPattern([5, 5, 200]))
        // Real capture from a Mac with AWDL active: fast and slow echoes alternate, so this is not plain congestion.
        XCTAssertEqual(Causes.burstPattern([3, 119, 3, 138, 3, 144, 3, 134, 3, 125, 4, 153, 4, 146, 22, 131, 4, 4, 6, 4]), .bursts)
        // Lost echoes (-1) are ignored when judging the shape.
        XCTAssertEqual(Causes.burstPattern([-1, -1, 90, 95, 100, 92, 97, 99, 101, 94]), .congestion)
    }

    func testBurstShapeIsPartOfTheCauses() {
        let s = spike(link: calmLink, system: calmSystem, burst: Array(repeating: 150, count: 20))
        XCTAssertEqual(Causes.causes(for: s), [.congestion])
    }

    func testLogLinesWrittenBeforeContextExistedStillDecode() throws {
        let legacy = #"{"t":"2026-10-28T19:07:10Z","vpn":true,"verdict":"ok","iface":"en0","gw":{"sent":3,"received":3,"avgMs":4.2,"maxMs":6}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let s = try decoder.decode(Sample.self, from: Data(legacy.utf8))
        XCTAssertNil(s.link)
        XCTAssertNil(s.gwBurst)
        XCTAssertNil(s.gw?.minMs)
    }

    func testNettopSecondBlockIsTheDelta() {
        let output = """
        ,bytes_in,bytes_out,
        Telegram.13754,9000000000,100,
        Tunnel.28469,9000000000,100,
        ,bytes_in,bytes_out,
        Telegram.13754,1500000,50000,
        Tunnel.28469,1600000,60000,
        mDNSResponder.488,900000,0,
        Safari.608,100,200,
        com.apple.WebKi.895,300000,60000,

        """
        let top = Talkers.parse(output, count: 3, minBytesPerSecond: 20_000)
        XCTAssertEqual(top, ["Telegram 1.6 МБ/с", "com.apple.WebKi 360 КБ/с"])
    }

    func testNettopGarbageIsRejected() {
        XCTAssertNil(Talkers.parse("nothing useful", count: 3, minBytesPerSecond: 1))
    }
}
