import XCTest
@testable import NetWatchCore

final class DiagnosisTests: XCTestCase {
    private let good = Probe(sent: 3, received: 3, avgMs: 5, maxMs: 6)
    private let dead = Probe(sent: 3, received: 0)

    private func healthy(at t: Date = Date()) -> Sample {
        Sample(t: t, iface: "en0", gateway: "192.168.0.1", vpn: false,
               gw: good, direct: good, direct2: good,
               dnsServer: "192.168.0.1", dnsMs: 20, tcpDirectMs: 15, httpMs: 80)
    }

    func testHealthyIsOK() {
        XCTAssertEqual(Diagnosis.verdict(for: healthy()), .ok)
    }

    func testNoGatewayMeansNoLink() {
        var s = healthy(); s.gateway = nil
        XCTAssertEqual(Diagnosis.verdict(for: s), .noLink)
    }

    func testNothingGetsThroughBlamesWifiOrRouter() {
        var s = healthy(); s.gw = dead; s.direct = dead; s.direct2 = dead; s.tcpDirectMs = nil
        XCTAssertEqual(Diagnosis.verdict(for: s), .wifiOrRouter)
    }

    func testSilentRouterWithWorkingInternetIsOnlyDegraded() {
        var s = healthy(); s.gw = dead
        XCTAssertEqual(Diagnosis.verdict(for: s), .degraded)
    }

    func testSingleLostPacketIsIgnored() {
        var s = healthy(); s.direct2 = Probe(sent: 3, received: 2, avgMs: 16, maxMs: 17)
        XCTAssertEqual(Diagnosis.verdict(for: s), .ok)
    }

    func testInternetDownBlamesProvider() {
        var s = healthy(); s.direct = dead; s.direct2 = dead; s.tcpDirectMs = nil
        XCTAssertEqual(Diagnosis.verdict(for: s), .isp)
    }

    func testOneIcmpTargetDownIsOnlyDegraded() {
        var s = healthy(); s.direct = dead
        XCTAssertEqual(Diagnosis.verdict(for: s), .degraded)
    }

    func testDnsFailure() {
        var s = healthy(); s.dnsMs = nil
        XCTAssertEqual(Diagnosis.verdict(for: s), .dns)
    }

    func testVpnFailureOnlyWhenDirectPathWorks() {
        var s = healthy(); s.vpn = true; s.httpMs = nil
        XCTAssertEqual(Diagnosis.verdict(for: s), .vpn)
    }

    func testSlowRouterIsDegraded() {
        var s = healthy(); s.gw = Probe(sent: 3, received: 3, avgMs: 80, maxMs: 90)
        XCTAssertEqual(Diagnosis.verdict(for: s), .degraded)
    }

    func testIncidentsMergeCloseSamplesAndKeepWorstVerdict() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func sample(_ dt: TimeInterval, _ v: Verdict) -> Sample { var s = healthy(at: t0.addingTimeInterval(dt)); s.verdict = v; return s }
        let samples = [sample(0, .ok), sample(10, .degraded), sample(13, .wifiOrRouter), sample(16, .ok),
                       sample(300, .dns), sample(303, .ok)]
        let incidents = Diagnosis.incidents(from: samples)
        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].verdict, .wifiOrRouter)
        XCTAssertEqual(incidents[0].samples, 2)
        XCTAssertEqual(incidents[1].verdict, .dns)
    }

    func testChannelChangeDetectsDFS() {
        func wifi(_ ch: Int, dfs: Bool) -> WiFiInfo {
            WiFiInfo(interface: "en0", rssi: -50, noise: -90, txRateMbps: 400, channel: ch, band: "5GHz", isDFS: dfs)
        }
        var a = healthy(at: Date(timeIntervalSince1970: 100)); a.wifi = wifi(56, dfs: true)
        var b = healthy(at: Date(timeIntervalSince1970: 130)); b.wifi = wifi(36, dfs: false)
        let changes = Diagnosis.channelChanges([a, b])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].from, 56)
        XCTAssertTrue(changes[0].involvesDFS)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netwatch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SampleStore(dir: dir)
        let s = healthy()
        store.append(s)
        let loaded = store.load(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].gateway, "192.168.0.1")
    }
}
