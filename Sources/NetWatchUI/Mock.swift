import Foundation
import NetWatchCore

/// Synthetic data for widget placeholders, PNG previews and the README animations. Nothing here comes from a real network.
public enum Mock {
    /// A stretch of time during which the network is in the given state.
    public struct Outage {
        public var start: Date
        public var end: Date
        public var verdict: Verdict

        public init(start: Date, end: Date, verdict: Verdict) {
            self.start = start
            self.end = end
            self.verdict = verdict
        }
    }

    /// - Parameters:
    ///   - current: state of the last two minutes.
    ///   - events: a few canned outages placed at fixed "minutes ago" offsets. Switch it off for animations, where such events
    ///     would stay put while the time moves on instead of scrolling away.
    ///   - outages: problems at absolute times, which scroll naturally as `now` advances.
    public static func snapshot(now: Date = Date(), current: Verdict = .ok, days: Int = 1, range: StatsRange = .hour,
                                events: Bool = true, outages: [Outage] = []) -> WidgetSnapshot {
        let dead = Probe(sent: 3, received: 0)
        let wifi = WiFiInfo(interface: "en0", rssi: -37, noise: -94, txRateMbps: 433, channel: 56, band: "5GHz", isDFS: true)

        func apply(_ verdict: Verdict, to s: inout Sample) {
            switch verdict {
            case .ok: break
            case .degraded:
                s.gw = Probe(sent: 3, received: 3, avgMs: 85, maxMs: 90)
                s.direct = Probe(sent: 3, received: 3, avgMs: 110, maxMs: 120)
                s.direct2 = Probe(sent: 3, received: 3, avgMs: 118, maxMs: 125)
            case .dns: s.dnsMs = nil
            case .vpn: s.httpMs = nil
            case .isp: s.direct = dead; s.direct2 = dead; s.tcpDirectMs = nil
            case .wifiOrRouter: s.gw = dead; s.direct = dead; s.direct2 = dead; s.tcpDirectMs = nil; s.dnsMs = nil; s.httpMs = nil
            case .noLink: s.gateway = nil
            }
        }

        var samples: [Sample] = []
        var t = now.addingTimeInterval(-Double(days) * 86_400)
        var n = 0

        while t <= now {
            let ago = now.timeIntervalSince(t) / 60 // minutes
            let wobble = abs(sin(Double(n) * 0.7))
            var s = Sample(
                t: t, iface: "en0", gateway: "192.168.0.1", vpn: true,
                gw: Probe(sent: 3, received: 3, avgMs: 3 + wobble * 2, maxMs: 6),
                direct: Probe(sent: 3, received: 3, avgMs: 12 + wobble * 4, maxMs: 20),
                direct2: Probe(sent: 3, received: 3, avgMs: 16, maxMs: 19),
                dnsServer: "192.168.0.1", dnsMs: 22 + wobble * 6, tcpDirectMs: 14, httpMs: 110 + wobble * 90,
                wifi: wifi,
                router: RouterStats(wanDownKBps: 18 + wobble * 40, wanUpKBps: 5 + wobble * 8, clients: 2, wanUptime: 8500, wanStatus: "1310007")
            )
            if events {
                if (35...37).contains(ago) || (1300...1303).contains(ago) { apply(.wifiOrRouter, to: &s) }
                if (18...20).contains(ago) { // latency spike on both targets, otherwise the best-of-two hides it
                    s.direct = Probe(sent: 3, received: 3, avgMs: 85, maxMs: 120)
                    s.direct2 = Probe(sent: 3, received: 3, avgMs: 92, maxMs: 130)
                }
                if (300...303).contains(ago) || (4000...4004).contains(ago) { apply(.dns, to: &s) }
                if (7300...7310).contains(ago) { s.direct = Probe(sent: 3, received: 3, avgMs: 140, maxMs: 200); s.direct2 = s.direct } // slow evening
                if (900...904).contains(ago) { apply(.isp, to: &s) }
            }
            for o in outages where t >= o.start && t < o.end { apply(o.verdict, to: &s) }
            if ago < 2 { apply(current, to: &s) }

            s.verdict = Diagnosis.verdict(for: s)
            samples.append(s)
            t = t.addingTimeInterval(60)
            n += 1
        }
        // Like the real widget: raw samples for the last day, rollups for anything longer.
        let recent = samples.filter { $0.t >= now.addingTimeInterval(-86_400) }
        return WidgetSnapshot.make(samples: recent, now: now, range: range, rollups: Rollups.build(samples, known: []))
    }
}
