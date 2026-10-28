import Foundation

/// What has already been announced, so one incident produces one notification.
public struct AlertState: Equatable, Sendable {
    /// Start of the incident the user was last told about; nil when nothing is open.
    public var notifiedSince: Date?
    public var lastProblemAlert: Date?

    public init(notifiedSince: Date? = nil, lastProblemAlert: Date? = nil) {
        self.notifiedSince = notifiedSince
        self.lastProblemAlert = lastProblemAlert
    }
}

public struct Alert: Equatable, Sendable {
    public enum Kind: Sendable { case problem, recovered }

    public var kind: Kind
    public var title: String
    public var body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

public enum Alerts {
    /// A problem has to last this long before it is worth interrupting someone.
    public static let holdTime: TimeInterval = 60
    /// Never more than one "problem" notification in this window, however jittery the network is.
    public static let minGapBetweenAlerts: TimeInterval = 300
    /// Non-OK samples this close together belong to one incident; also how long an incident counts as ongoing.
    private static let ongoingGap: TimeInterval = 90

    /// Decides whether the latest samples warrant a notification, and updates `state` accordingly.
    public static func next(samples: [Sample], now: Date = Date(), state: inout AlertState) -> Alert? {
        let recent = samples.filter { $0.t <= now && $0.t >= now.addingTimeInterval(-1800) }.sorted { $0.t < $1.t }
        // No fresh data means the agent is not running: say nothing rather than guess.
        guard let latest = recent.last, now.timeIntervalSince(latest.t) <= WidgetSnapshot.staleAfter else { return nil }

        let incidents = Diagnosis.incidents(from: recent, maxGap: ongoingGap)
        if let last = incidents.last, now.timeIntervalSince(last.end) <= ongoingGap {
            guard last.duration >= holdTime, state.notifiedSince != last.start else { return nil }
            if let prev = state.lastProblemAlert, now.timeIntervalSince(prev) < minGapBetweenAlerts { return nil }
            state.notifiedSince = last.start
            state.lastProblemAlert = now
            return problem(last, recent: recent, now: now)
        }

        guard let since = state.notifiedSince else { return nil }
        state.notifiedSince = nil
        let lasted = incidents.first { $0.start == since }.map { " Проблема длилась \(duration($0.duration))." } ?? ""
        return Alert(kind: .recovered, title: "NetWatch · связь восстановилась", body: "Сеть снова в порядке.\(lasted)")
    }

    private static func problem(_ incident: Incident, recent: [Sample], now: Date) -> Alert {
        let snapshot = WidgetSnapshot.make(samples: recent, now: now)
        var lines = [snapshot.detail]

        // Name the likeliest cause when the router itself was slow and context was recorded.
        var counts: [SpikeCause: Int] = [:]
        for s in recent where s.t >= incident.start && s.t <= incident.end && Causes.isLocalSpike(s) {
            for c in Causes.causes(for: s) { counts[c, default: 0] += 1 }
        }
        // A concrete cause beats "nothing local found" even when the latter was seen more often.
        let top = counts.max { a, b in
            (a.value, a.key != .external ? 1 : 0) < (b.value, b.key != .external ? 1 : 0)
        }?.key
        if let top { lines.append("Вероятная причина: \(top.title)") }
        lines.append("Идёт уже \(duration(incident.duration)).")
        return Alert(kind: .problem, title: "NetWatch · \(snapshot.headline)", body: lines.joined(separator: "\n"))
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s < 90 ? "\(s) с" : "\(Int((t / 60).rounded())) мин"
    }
}
