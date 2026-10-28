import XCTest
@testable import NetWatchCore

final class RouterTests: XCTestCase {
    // Shaped like the router's replies, with invented values.
    private let routerStatus = #"""
    {"clientNum":3,"wl24gName":"net","wanInfo":[{"wanStatus":"1000000","wanIp":"203.0.113.7","wanUploadSpeed":"5.48","wanDownloadSpeed":"26.42"}]}
    """#
    private let wanParameters = #"""
    {"wanInfo":[{"wanType":"0","connectTime":"4200","connectStatus":"1000000"}]}
    """#

    func testRouterStatusIsParsedIncludingNumbersSentAsStrings() throws {
        let stats = try XCTUnwrap(TendaClient.parseRouterStatus(Data(routerStatus.utf8)))
        XCTAssertEqual(stats.clients, 3)
        XCTAssertEqual(stats.wanDownKBps, 26.42)
        XCTAssertEqual(stats.wanUpKBps, 5.48)
        XCTAssertEqual(stats.wanStatus, "1000000")
    }

    func testWanUptimeIsReadFromTheOtherEndpoint() {
        XCTAssertEqual(TendaClient.parseWanUptime(Data(wanParameters.utf8)), 4200)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(TendaClient.parseRouterStatus(Data("<html>login</html>".utf8)))
        XCTAssertNil(TendaClient.parseWanUptime(Data("[]".utf8)))
    }

    func testAReconnectIsTheUptimeCounterGoingBackwards() {
        XCTAssertTrue(RouterStats.isReconnect(previousUptime: 8380, uptime: 12))
        XCTAssertFalse(RouterStats.isReconnect(previousUptime: 8380, uptime: 8410), "normal growth")
        XCTAssertFalse(RouterStats.isReconnect(previousUptime: 8380, uptime: 8377), "a few seconds of jitter is not a reconnect")
        XCTAssertFalse(RouterStats.isReconnect(previousUptime: nil, uptime: 12), "the first reading proves nothing")
    }

    // MARK: Blaming other devices

    private func spike(router: RouterStats?, ownBps: Double) -> Sample {
        Sample(iface: "en0", gateway: "192.168.0.1", gw: Probe(sent: 3, received: 3, avgMs: 120, maxMs: 200), verdict: .degraded,
               link: LinkStats(rxBps: ownBps, txBps: 0), system: SystemStats(load1: 1, cores: 8), router: router)
    }

    func testTrafficThisMacDoesNotExplainPointsAtOtherDevices() {
        // 8 MB/s crosses the router, the Mac itself only moves 50 KB/s.
        let s = spike(router: RouterStats(wanDownKBps: 8 * 1024), ownBps: 50_000)
        XCTAssertEqual(Causes.causes(for: s), [.otherDevices])
    }

    func testTrafficFromThisMacIsNotBlamedOnOthers() {
        let s = spike(router: RouterStats(wanDownKBps: 8 * 1024), ownBps: 8 * 1_048_576)
        XCTAssertEqual(Causes.causes(for: s), [.ownTraffic])
    }

    func testQuietRouterBlamesNobody() {
        let s = spike(router: RouterStats(wanDownKBps: 12, wanUpKBps: 4), ownBps: 3_000)
        XCTAssertEqual(Causes.causes(for: s), [.external])
    }

    // MARK: Report

    func testReportShowsReconnectsAndTrafficDuringSpikes() {
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        func sample(_ t: TimeInterval, gw: Double, down: Double, reconnected: Bool = false) -> Sample {
            let good = Probe(sent: 3, received: 3, avgMs: 13, maxMs: 14)
            var s = Sample(t: t0.addingTimeInterval(t), iface: "en0", gateway: "192.168.0.1",
                           gw: Probe(sent: 3, received: 3, avgMs: gw, maxMs: gw), direct: good, direct2: good,
                           dnsServer: "1.1.1.1", dnsMs: 20, tcpDirectMs: 14, httpMs: 100,
                           network: NetworkKey(id: "n1", gateway: "192.168.0.1"),
                           router: RouterStats(wanDownKBps: down, wanUpKBps: 1, clients: 2, wanUptime: 1000, reconnected: reconnected ? true : nil))
            s.verdict = Diagnosis.verdict(for: s)
            return s
        }
        let samples = [sample(0, gw: 4, down: 100), sample(30, gw: 150, down: 6000), sample(60, gw: 4, down: 120, reconnected: true)]
        let text = Report.text(samples: samples, since: t0, now: t0.addingTimeInterval(120))
        XCTAssertTrue(text.contains("Заново подключался к провайдеру: 1"), text)
        XCTAssertTrue(text.contains("Устройств в сети: 2"), text)
        XCTAssertTrue(text.contains("Во время скачков задержки до роутера: ↓5.86 МБ/с"), text)
    }
}
