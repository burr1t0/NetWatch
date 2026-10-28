import Foundation

public struct Incident: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var verdict: Verdict
    public var samples: Int

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct ChannelChange: Equatable, Sendable {
    public var at: Date
    public var from: Int
    public var to: Int
    public var involvesDFS: Bool
}

public enum Diagnosis {
    /// Decides which layer is at fault, walking outwards: link → router → internet → DNS → VPN → quality.
    public static func verdict(for s: Sample) -> Verdict {
        guard s.iface != nil, s.gateway != nil else { return .noLink }

        // The router only counts as "down" when nothing gets through it: packets reaching the internet prove it forwards.
        let gwSilent = (s.gw?.loss ?? 1) >= 0.5
        let internetDown = (s.direct?.loss ?? 1) >= 0.5 && (s.direct2?.loss ?? 1) >= 0.5 && s.tcpDirectMs == nil
        if internetDown { return gwSilent ? .wifiOrRouter : .isp }
        if s.dnsServer != nil && s.dnsMs == nil { return .dns }
        if s.vpn && s.httpMs == nil { return .vpn }

        // A single lost packet is noise; flag only when more than a fifth of all echoes vanished.
        let probes = [s.gw, s.direct, s.direct2].compactMap { $0 }
        let sent = probes.reduce(0) { $0 + $1.sent }
        let lost = probes.reduce(0) { $0 + $1.sent - $1.received }
        let lossy = sent > 0 && Double(lost) / Double(sent) > 0.2
        let slow = (s.gw?.avgMs ?? 0) > 30
            || (s.directRttMs ?? 0) > 150
            || (s.dnsMs ?? 0) > 300
            || (s.httpMs ?? 0) > 3000
        return gwSilent || lossy || slow ? .degraded : .ok
    }

    /// Consecutive non-OK samples (no more than `maxGap` apart) form one incident.
    public static func incidents(from samples: [Sample], maxGap: TimeInterval = 90) -> [Incident] {
        var result: [Incident] = []
        for s in samples.sorted(by: { $0.t < $1.t }) where s.verdict != .ok {
            if var last = result.last, s.t.timeIntervalSince(last.end) <= maxGap {
                last.end = s.t
                last.samples += 1
                if s.verdict.severity > last.verdict.severity { last.verdict = s.verdict }
                result[result.count - 1] = last
            } else {
                result.append(Incident(start: s.t, end: s.t, verdict: s.verdict, samples: 1))
            }
        }
        return result
    }

    public static func channelChanges(_ samples: [Sample]) -> [ChannelChange] {
        var result: [ChannelChange] = []
        var prev: WiFiInfo?
        for s in samples.sorted(by: { $0.t < $1.t }) {
            guard let w = s.wifi else { continue }
            if let p = prev, p.channel != w.channel {
                result.append(ChannelChange(at: s.t, from: p.channel, to: w.channel, involvesDFS: p.isDFS || w.isDFS))
            }
            prev = w
        }
        return result
    }
}
