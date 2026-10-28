import Foundation

/// One slot of the graph. Spikes matter more than averages, so values are maxima.
public struct GraphBucket: Equatable, Sendable {
    public var start: Date
    public var gwMs: Double?
    public var rttMs: Double?
    /// Worst verdict seen in this slot; nil when nothing was measured.
    public var verdict: Verdict?
}

/// Everything a widget needs, precomputed from the log so the views stay dumb.
public struct WidgetSnapshot: Sendable {
    /// Slots of the one-hour graph.
    public static let bucketCount = 60
    /// Normal cadence is 30–60 s, so three minutes of silence means the agent is not running.
    public static let staleAfter: TimeInterval = 180

    public var generatedAt: Date
    public var latest: Sample?
    public var isStale: Bool
    /// Verdict of the latest sample; nil when there is no fresh data.
    public var status: Verdict?
    public var headline: String
    public var detail: String
    public var buckets: [GraphBucket]
    /// Newest first.
    public var incidents: [Incident]
    /// Share of the chosen range spent in the OK state, 0...1.
    public var availability: Double?
    /// The network everything above refers to: the one the newest sample was taken on.
    public var networkID: String?
    public var networkName: String?
    public var range: StatsRange

    /// Builds the picture for the network the Mac is on now; samples from other networks are left out.
    /// The hour graph comes from raw samples. Day and week come from `rollups`, because raw samples for that long are too heavy.
    public static func make(samples: [Sample], now: Date = Date(), networks: [KnownNetwork] = [],
                            range: StatsRange = .hour, rollups: [Rollup] = []) -> WidgetSnapshot {
        let all = samples.filter { $0.t <= now }.sorted { $0.t < $1.t }
        let (sorted, networkID) = Networks.currentOnly(all, known: networks)
        let latest = sorted.last
        let stale = latest.map { now.timeIntervalSince($0.t) > staleAfter } ?? true

        let graph = range == .hour
            ? hourGraph(sorted, now: now)
            : longGraph(range, networkID: networkID, now: now, rollups: rollups)

        let incidents: [Incident]
        if range == .week {
            let from = now.addingTimeInterval(-range.duration)
            incidents = Rollups.incidents(rollups.filter { $0.network == networkID && $0.start >= from })
        } else {
            incidents = Diagnosis.incidents(from: sorted)
        }

        let (headline, detail) = describe(latest: latest, stale: stale, now: now)
        return WidgetSnapshot(
            generatedAt: now, latest: latest, isStale: stale,
            status: stale ? nil : latest?.verdict,
            headline: headline, detail: detail, buckets: graph.buckets,
            incidents: Array(incidents.reversed().prefix(4)),
            availability: graph.availability,
            networkID: networkID,
            networkName: networkID.map { Networks.name(for: $0, known: networks) },
            range: range
        )
    }

    private static func hourGraph(_ sorted: [Sample], now: Date) -> (buckets: [GraphBucket], availability: Double?) {
        let hourStart = now.addingTimeInterval(-3600)
        let hour = sorted.filter { $0.t >= hourStart }
        var buckets = (0..<bucketCount).map { GraphBucket(start: hourStart.addingTimeInterval(Double($0) * 60)) }
        for s in hour {
            let i = min(bucketCount - 1, max(0, Int(s.t.timeIntervalSince(hourStart) / 60)))
            if let g = s.gw?.avgMs { buckets[i].gwMs = max(buckets[i].gwMs ?? 0, g) }
            if let r = s.directRttMs { buckets[i].rttMs = max(buckets[i].rttMs ?? 0, r) }
            if (buckets[i].verdict?.severity ?? -1) < s.verdict.severity { buckets[i].verdict = s.verdict }
        }

        var availability: Double?
        if !hour.isEmpty {
            let w = Report.weights(hour)
            let total = w.reduce(0, +)
            let ok = zip(hour, w).filter { $0.0.verdict == .ok }.reduce(0) { $0 + $1.1 }
            availability = total > 0 ? ok / total : nil
        }
        return (buckets, availability)
    }

    private static func longGraph(_ range: StatsRange, networkID: String?, now: Date, rollups: [Rollup]) -> (buckets: [GraphBucket], availability: Double?) {
        let n = range.bucketCount
        let start = now.addingTimeInterval(-range.duration)
        var buckets = (0..<n).map { GraphBucket(start: start.addingTimeInterval(Double($0) * range.bucketSeconds)) }
        var seconds = 0.0
        var okSeconds = 0.0
        for r in rollups where r.network == networkID && r.start >= start.addingTimeInterval(-Rollups.step) && r.start < now {
            let i = min(n - 1, max(0, Int(r.start.timeIntervalSince(start) / range.bucketSeconds)))
            if let g = r.gwMax { buckets[i].gwMs = max(buckets[i].gwMs ?? 0, g) }
            if let d = r.rttMax { buckets[i].rttMs = max(buckets[i].rttMs ?? 0, d) }
            if (buckets[i].verdict?.severity ?? -1) < r.worst.severity { buckets[i].verdict = r.worst }
            seconds += r.seconds
            okSeconds += r.okSeconds
        }
        return (buckets, seconds > 0 ? okSeconds / seconds : nil)
    }

    private static func ms(_ v: Double?) -> String { v.map { String(format: "%.0f мс", $0) } ?? "—" }

    private static func describe(latest: Sample?, stale: Bool, now: Date) -> (String, String) {
        guard let s = latest else { return ("Нет данных", "Агент netwatchd не запущен") }
        if stale {
            let minutes = max(1, Int(now.timeIntervalSince(s.t) / 60))
            return ("Нет свежих данных", "Последний замер \(minutes) мин назад — агент остановлен?")
        }
        switch s.verdict {
        case .ok: return ("Всё в порядке", "Роутер \(ms(s.gw?.avgMs)) · интернет \(ms(s.directRttMs))")
        case .degraded: return ("Нестабильное соединение", reason(s))
        case .dns: return ("Проблема с DNS", "Сервер \(s.dnsServer ?? "—") не отвечает")
        case .vpn: return ("Проблема с VPN", "Напрямую интернет работает, через VPN — нет")
        case .isp: return ("Проблема у провайдера", "Роутер отвечает, интернета нет")
        case .wifiOrRouter: return ("Wi-Fi или роутер", "Через роутер не проходит ничего")
        case .noLink: return ("Нет сети", "Нет подключения к роутеру")
        }
    }

    /// Spells out why a sample was flagged as degraded, mirroring the thresholds in `Diagnosis`.
    private static func reason(_ s: Sample) -> String {
        var parts: [String] = []
        if s.gwIcmpFiltered != true, (s.gw?.loss ?? 0) >= 0.5 { parts.append("роутер не отвечает на ping") }
        let probes = [s.gwIcmpFiltered == true ? nil : s.gw,
                      s.externalIcmpFiltered == true ? nil : s.direct,
                      s.externalIcmpFiltered == true ? nil : s.direct2].compactMap { $0 }
        let sent = probes.reduce(0) { $0 + $1.sent }
        let lost = probes.reduce(0) { $0 + $1.sent - $1.received }
        if sent > 0, Double(lost) / Double(sent) > 0.2 { parts.append("потери пакетов \(Int((Double(lost) / Double(sent) * 100).rounded()))%") }
        if s.gwIcmpFiltered != true, let g = s.gw?.avgMs, g > 30 { parts.append("роутер \(ms(g))") }
        if let d = s.directRttMs, d > 150 { parts.append("интернет \(ms(d))") }
        if let d = s.dnsMs, d > 300 { parts.append("DNS \(ms(d))") }
        if let h = s.httpMs, h > 3000 { parts.append("HTTPS \(String(format: "%.1f", h / 1000)) с") }
        return parts.isEmpty ? "Есть отклонения" : parts.joined(separator: ", ")
    }
}
