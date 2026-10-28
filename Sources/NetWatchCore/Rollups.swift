import Foundation

/// A quarter of an hour of samples for one network, boiled down. A week of raw samples is tens of megabytes,
/// far too much for a widget; a week of rollups is a few hundred small records.
public struct Rollup: Codable, Equatable, Sendable {
    /// Aligned to `Rollups.step`.
    public var start: Date
    public var network: String?
    /// Observed time this rollup stands for, and how much of it was OK (long gaps such as sleep are capped, as in reports).
    public var seconds: Double
    public var okSeconds: Double
    public var gwMax: Double?
    public var rttMax: Double?
    public var worst: Verdict

    public init(start: Date, network: String?, seconds: Double = 0, okSeconds: Double = 0,
                gwMax: Double? = nil, rttMax: Double? = nil, worst: Verdict = .ok) {
        self.start = start
        self.network = network
        self.seconds = seconds
        self.okSeconds = okSeconds
        self.gwMax = gwMax
        self.rttMax = rttMax
        self.worst = worst
    }
}

public enum Rollups {
    public static let step: TimeInterval = 900

    private struct Key: Hashable {
        var start: Date
        var network: String?
    }

    /// Groups samples by quarter hour and network. Peaks are kept as maxima, because for diagnosing a slowdown
    /// the worst moment matters more than the average.
    public static func build(_ samples: [Sample], known: [KnownNetwork]) -> [Rollup] {
        let sorted = samples.sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }
        let ids = Networks.ids(for: sorted, known: known)
        let weights = Report.weights(sorted)

        var acc: [Key: Rollup] = [:]
        for (i, s) in sorted.enumerated() {
            guard let network = ids[i] else { continue }
            let start = Date(timeIntervalSince1970: (s.t.timeIntervalSince1970 / step).rounded(.down) * step)
            let key = Key(start: start, network: network)
            var r = acc[key] ?? Rollup(start: start, network: network)
            r.seconds += weights[i]
            if s.verdict == .ok { r.okSeconds += weights[i] }
            if let g = s.gw?.avgMs { r.gwMax = max(r.gwMax ?? 0, g) }
            if let d = s.directRttMs { r.rttMax = max(r.rttMax ?? 0, d) }
            if s.verdict.severity > r.worst.severity { r.worst = s.verdict }
            acc[key] = r
        }
        return ordered(acc.values)
    }

    /// Rollups for the newest raw samples only, starting at the first full quarter hour so a half-filled bucket
    /// can never replace a complete stored one.
    public static func fresh(samples: [Sample], now: Date, known: [KnownNetwork], window: TimeInterval = 7200) -> [Rollup] {
        let from = ((now.timeIntervalSince1970 - window) / step).rounded(.up) * step
        return build(samples.filter { $0.t.timeIntervalSince1970 >= from }, known: known)
    }

    /// `new` replaces `old` where both describe the same quarter hour of the same network; anything before `keepSince` is dropped.
    public static func merge(_ old: [Rollup], with new: [Rollup], keepSince: Date) -> [Rollup] {
        var map: [Key: Rollup] = [:]
        for r in old where r.start >= keepSince { map[Key(start: r.start, network: r.network)] = r }
        for r in new { map[Key(start: r.start, network: r.network)] = r }
        return ordered(map.values)
    }

    /// Incidents over a long range: runs of quarter hours that were not OK (one quiet quarter between two bad ones
    /// does not end a run). The duration is the time actually spent in a bad state, not the width of the run.
    public static func incidents(_ rollups: [Rollup]) -> [Incident] {
        var runs: [(first: Date, last: Date, bad: Double, worst: Verdict, count: Int)] = []
        for r in rollups.sorted(by: { $0.start < $1.start }) where r.worst != .ok {
            let bad = max(1, r.seconds - r.okSeconds)
            if let last = runs.last, r.start.timeIntervalSince(last.last) <= step * 2 {
                runs[runs.count - 1].last = r.start
                runs[runs.count - 1].bad += bad
                runs[runs.count - 1].count += 1
                if r.worst.severity > last.worst.severity { runs[runs.count - 1].worst = r.worst }
            } else {
                runs.append((r.start, r.start, bad, r.worst, 1))
            }
        }
        return runs.map { Incident(start: $0.first, end: $0.first.addingTimeInterval($0.bad), verdict: $0.worst, samples: $0.count) }
    }

    private static func ordered(_ values: some Collection<Rollup>) -> [Rollup] {
        values.sorted { ($0.start, $0.network ?? "") < ($1.start, $1.network ?? "") }
    }
}

/// `rollups.json` next to the sample log. The agent writes it, the widget and the app read it.
public final class RollupStore {
    private let url: URL
    private let queue = DispatchQueue(label: "netwatch.rollups")

    public init(dir: URL = SampleStore.defaultDir) {
        url = dir.appendingPathComponent("rollups.json")
    }

    public func load(since: Date) -> [Rollup] {
        queue.sync { read().filter { $0.start >= since } }
    }

    /// Recomputes the rollups for `from`...`to` from the raw log and merges them in. `from` is moved back to a quarter-hour
    /// boundary, so the first bucket is always built from all of its samples.
    public func update(store: SampleStore, networks: [KnownNetwork], from: Date, to: Date = Date()) {
        let aligned = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / Rollups.step).rounded(.down) * Rollups.step)
        let built = Rollups.build(store.load(since: aligned, until: to), known: networks)
        queue.sync {
            write(Rollups.merge(read(), with: built, keepSince: Date().addingTimeInterval(-35 * 86_400)))
        }
    }

    private func read() -> [Rollup] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Rollup].self, from: data)) ?? []
    }

    private func write(_ list: [Rollup]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}
