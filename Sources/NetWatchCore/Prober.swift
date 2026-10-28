import Foundation

private func offload<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
    }
}

/// Runs one full measurement round. All probes run concurrently, so a round takes about as long as the slowest one.
/// Not thread-safe: the monitor calls `sample()` one round at a time.
public final class Prober {
    public var testURL = URL(string: "https://www.apple.com/library/test/success.html")!
    /// Collect the problem-time evidence (echo burst, top processes) even when everything looks fine.
    public var forceContext = false

    private var lastCounters: (at: UInt64, stats: [String: SystemInfo.IfCounters])?
    private var lastBurst = Date.distantPast
    private var lastTalkers = Date.distantPast

    public init() {}

    public func sample() async -> Sample {
        let env = SystemInfo.environment()
        var s = Sample(iface: env.iface, gateway: env.gateway, vpn: env.vpn, wifi: SystemInfo.wifi())
        s.system = SystemInfo.systemStats()
        s.link = linkStats(iface: env.iface)
        guard let iface = env.iface, let gateway = env.gateway else {
            s.verdict = Diagnosis.verdict(for: s)
            return s
        }

        let dnsServers = Array(env.dnsServers.prefix(2))
        async let gw = offload { Sock.icmpPing(host: gateway, iface: iface, count: 3, intervalMs: 150, timeoutMs: 800) }
        async let d1 = offload { Sock.icmpPing(host: "1.1.1.1", iface: iface, count: 3, intervalMs: 150, timeoutMs: 1000) }
        async let d2 = offload { Sock.icmpPing(host: "8.8.8.8", iface: iface, count: 3, intervalMs: 150, timeoutMs: 1000) }
        async let tcp = offload { Sock.tcpConnect(host: "1.1.1.1", port: 443, iface: iface, timeoutMs: 2000) }
        async let dns = offload { () -> (String?, Double?) in
            for server in dnsServers {
                if let ms = Sock.dnsQuery(server: server, iface: iface, timeoutMs: 1500) { return (server, ms) }
            }
            return (dnsServers.last, nil)
        }
        async let http = httpProbe()

        s.gw = await gw
        s.direct = await d1
        s.direct2 = await d2
        s.tcpDirectMs = await tcp
        (s.dnsServer, s.dnsMs) = await dns
        s.httpMs = await http
        s.verdict = Diagnosis.verdict(for: s)

        if s.verdict != .ok || forceContext { await addContext(to: &s, gateway: gateway, iface: iface) }
        return s
    }

    // MARK: Context

    private func linkStats(iface: String?) -> LinkStats? {
        let now = Clock.nowNs()
        let current = SystemInfo.interfaceCounters()
        defer { lastCounters = (now, current) }
        guard let iface, let prev = lastCounters, let a = current[iface], let b = prev.stats[iface] else { return nil }
        let dt = Double(now - prev.at) / 1e9
        guard dt > 0.5, dt < 120 else { return nil } // a long gap means sleep, and the average would be meaningless

        var awdl = 0
        if let x = current["awdl0"], let y = prev.stats["awdl0"] {
            awdl = Int(x.rx &- y.rx) + Int(x.tx &- y.tx)
        }
        return LinkStats(rxBps: Double(a.rx &- b.rx) / dt, txBps: Double(a.tx &- b.tx) / dt,
                         rxErrors: Int(a.rxErr &- b.rxErr), txErrors: Int(a.txErr &- b.txErr), awdlBytes: awdl)
    }

    /// Extra evidence gathered only while something is wrong, and rate-limited because it costs real work:
    /// the echo burst is cheap (about 2 s), the process list is not (see `Talkers`).
    private func addContext(to s: inout Sample, gateway: String, iface: String) async {
        let now = Date()
        let routerTrouble = (s.gw?.avgMs ?? 0) > 30 || (s.gw?.loss ?? 0) > 0
        let wantBurst = forceContext || (routerTrouble && now.timeIntervalSince(lastBurst) >= 15)
        let wantTalkers = forceContext || (Causes.isLocalSpike(s) && now.timeIntervalSince(lastTalkers) >= 300)
        if wantBurst { lastBurst = now }
        if wantTalkers { lastTalkers = now }

        async let burst: [Int]? = wantBurst ? offload {
            Sock.icmpSeries(host: gateway, iface: iface, count: 20, intervalMs: 100, timeoutMs: 600)
                .map { $0.map { Int($0.rounded()) } ?? -1 }
        } : nil
        async let talkers: [String]? = wantTalkers ? offload { Talkers.top() } : nil

        s.gwBurst = await burst
        s.talkers = await talkers
    }

    private func httpProbe() async -> Double? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let t0 = Clock.nowNs()
        do {
            let (_, response) = try await session.data(from: testURL)
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
            return Double(Clock.nowNs() - t0) / 1_000_000
        } catch {
            return nil
        }
    }
}
