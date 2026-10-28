import XCTest
@testable import NetWatchCore

final class NetworksTests: XCTestCase {
    private let home = NetworkKey(id: "aaaa0001", gateway: "192.168.0.1")
    private let campus = NetworkKey(id: "bbbb0002", gateway: "10.20.0.1")
    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func sample(_ t: TimeInterval, _ net: NetworkKey?, gateway: String? = "x", verdict: Verdict = .ok) -> Sample {
        let good = Probe(sent: 3, received: 3, avgMs: 13, maxMs: 14)
        var s = Sample(t: t0.addingTimeInterval(t), iface: net == nil && gateway == nil ? nil : "en0",
                       gateway: net?.gateway ?? gateway,
                       gw: Probe(sent: 3, received: 3, avgMs: 4, maxMs: 5), direct: good, direct2: good,
                       dnsServer: "1.1.1.1", dnsMs: 20, tcpDirectMs: 14, httpMs: 100, network: net)
        s.verdict = verdict
        return s
    }

    private func known(_ key: NetworkKey, name: String) -> KnownNetwork {
        KnownNetwork(id: key.id, gateway: key.gateway, name: name, customName: true, firstSeen: t0, lastSeen: t0)
    }

    // MARK: Identity and registry

    func testKeyIsStableAndDoesNotContainTheMac() {
        let a = NetworkKey.make(gateway: "192.168.0.1", mac: "02:00:00:00:00:01")
        XCTAssertEqual(a, NetworkKey.make(gateway: "192.168.0.1", mac: "02:00:00:00:00:01"))
        XCTAssertNotEqual(a.id, NetworkKey.make(gateway: "192.168.0.1", mac: "aa:bb:cc:dd:ee:ff").id)
        XCTAssertFalse(a.id.contains(":"))
        XCTAssertEqual(a.id.count, 8)
    }

    func testAutoNames() {
        XCTAssertEqual(NetworkRegistry.autoName(gateway: "172.20.10.1"), "Раздача iPhone")
        XCTAssertEqual(NetworkRegistry.autoName(gateway: "10.20.0.1"), "Сеть 10.20.0.1")
    }

    func testRegistryRemembersRenamesAndKeepsNamesUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netwatch-nets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = NetworkRegistry(dir: dir)

        XCTAssertEqual(registry.observe(home, at: t0).name, "Сеть 192.168.0.1")
        // The same gateway address on a different router (a friend's flat) must not share the name.
        let friend = NetworkKey(id: "cccc0003", gateway: "192.168.0.1")
        XCTAssertEqual(registry.observe(friend, at: t0).name, "Сеть 192.168.0.1 (2)")

        registry.rename(id: home.id, to: "  Дом  ")
        let reloaded = NetworkRegistry(dir: dir).all()
        XCTAssertEqual(reloaded.first { $0.id == home.id }?.name, "Дом")
        XCTAssertEqual(reloaded.first { $0.id == home.id }?.customName, true)
        XCTAssertEqual(registry.observe(home, at: t0.addingTimeInterval(5)).name, "Дом", "seeing a network again must not reset its name")

        registry.rename(id: home.id, to: "   ")
        XCTAssertEqual(registry.all().first { $0.id == home.id }?.name, "Дом", "an empty name is ignored")
    }

    func testLearnedFiltersArePersisted() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netwatch-nets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = NetworkRegistry(dir: dir)
        registry.observe(campus)
        registry.update(id: campus.id) { $0.externalIcmpFiltered = true }
        XCTAssertEqual(NetworkRegistry(dir: dir).observe(campus).externalIcmpFiltered, true)
    }

    // MARK: Assigning samples to networks

    func testSamplesWithoutARouterBelongToThePreviousNetwork() {
        let samples = [sample(0, home), sample(30, home), sample(60, nil, gateway: nil, verdict: .noLink), sample(90, campus)]
        let ids = Networks.ids(for: samples, known: [])
        XCTAssertEqual(ids, [home.id, home.id, home.id, campus.id])
    }

    func testOldSamplesAreMatchedByRouterAddressWhenUnambiguous() {
        let legacy = sample(0, nil, gateway: "192.168.0.1")
        XCTAssertEqual(Networks.ids(for: [legacy], known: [known(home, name: "Дом")]), [home.id])

        let twin = NetworkKey(id: "cccc0003", gateway: "192.168.0.1")
        XCTAssertEqual(Networks.ids(for: [legacy], known: [known(home, name: "Дом"), known(twin, name: "Дача")]), ["gw:192.168.0.1"])
    }

    func testPartitionPutsTheMostRecentNetworkFirst() {
        let samples = [sample(0, home), sample(30, home), sample(60, campus)]
        let groups = Networks.partition(samples, known: [])
        XCTAssertEqual(groups.map(\.id), [campus.id, home.id])
        XCTAssertEqual(groups.last?.samples.count, 2)
    }

    // MARK: What the widget, alerts and report show

    func testSnapshotShowsOnlyTheCurrentNetwork() {
        // Trouble at home earlier, then the Mac moved to campus where everything is fine.
        let samples = [sample(0, home, verdict: .degraded), sample(10, home, verdict: .degraded), sample(20, home), sample(600, campus), sample(630, campus)]
        let snap = WidgetSnapshot.make(samples: samples, now: t0.addingTimeInterval(640),
                                       networks: [known(home, name: "Дом"), known(campus, name: "Корпус А")])
        XCTAssertEqual(snap.networkName, "Корпус А")
        XCTAssertEqual(snap.incidents.count, 0, "home's incident is not this network's")
        XCTAssertEqual(snap.status, .ok)
    }

    func testAlertsIgnoreAnIncidentOnAPreviousNetwork() {
        var samples = (0..<12).map { sample(Double($0) * 10, home, verdict: .degraded) }
        samples += [sample(125, campus), sample(135, campus)]
        var state = AlertState()
        XCTAssertNil(Alerts.next(samples: samples, now: t0.addingTimeInterval(140), state: &state, networks: []))
    }

    func testAlertMentionsTheNetwork() {
        let samples = (0...12).map { sample(Double($0) * 10, home, verdict: .degraded) }
        var state = AlertState()
        let alert = Alerts.next(samples: samples, now: t0.addingTimeInterval(125), state: &state, networks: [known(home, name: "Дом")])
        XCTAssertTrue(alert?.body.contains("Сеть: Дом") ?? false, alert?.body ?? "no alert")
    }

    func testReportIsSplitByNetworkAndCanBeFiltered() {
        let samples = [sample(0, home), sample(30, home), sample(60, campus), sample(90, campus)]
        let nets = [known(home, name: "Дом"), known(campus, name: "Корпус А")]
        let both = Report.text(samples: samples, since: t0, now: t0.addingTimeInterval(120), networks: nets)
        XCTAssertTrue(both.contains("«Дом»") && both.contains("«Корпус А»"))

        let onlyCampus = Report.text(samples: samples, since: t0, now: t0.addingTimeInterval(120), networks: nets, only: "корпус")
        XCTAssertTrue(onlyCampus.contains("«Корпус А»"))
        XCTAssertFalse(onlyCampus.contains("«Дом»"))

        XCTAssertTrue(Report.text(samples: samples, since: t0, networks: nets, only: "нет такой").contains("Нет данных по этой сети"))
    }
}
