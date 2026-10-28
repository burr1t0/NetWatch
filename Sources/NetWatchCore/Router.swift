import Foundation

/// What a Tenda router reports about itself on its status page. The agent reads this next to its own measurements,
/// so a slowdown can be matched with what the router was doing, not only with what this Mac was doing.
public struct RouterStats: Codable, Equatable, Sendable {
    /// Traffic through the router's internet port right now, in KB/s (the unit the router's own page uses).
    public var wanDownKBps: Double?
    public var wanUpKBps: Double?
    public var clients: Int?
    /// Seconds since the router's connection to the provider was established.
    public var wanUptime: Int?
    /// Raw status code of that connection, kept as it comes because its meaning is not documented.
    public var wanStatus: String?
    /// The connection was re-established since the previous sample: the router rebooted or the provider dropped it.
    public var reconnected: Bool?

    public init(wanDownKBps: Double? = nil, wanUpKBps: Double? = nil, clients: Int? = nil,
                wanUptime: Int? = nil, wanStatus: String? = nil, reconnected: Bool? = nil) {
        self.wanDownKBps = wanDownKBps
        self.wanUpKBps = wanUpKBps
        self.clients = clients
        self.wanUptime = wanUptime
        self.wanStatus = wanStatus
        self.reconnected = reconnected
    }

    /// The uptime counter goes backwards when the connection restarts. A few seconds of slack absorbs jitter between reads.
    public static func isReconnect(previousUptime: Int?, uptime: Int?) -> Bool {
        guard let previousUptime, let uptime else { return false }
        return uptime + 5 < previousUptime
    }
}

/// Reads the status endpoints of Tenda's stock firmware. They answer on the LAN without a login (the router's own
/// status page uses them before anyone signs in), so no password is involved and nothing is ever written to the router.
enum TendaClient {
    enum Detection { case tenda, other, unreachable }

    private static func get(_ gateway: String, _ path: String) async -> (data: Data, status: Int)? {
        guard let url = URL(string: "http://\(gateway)/\(path)") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return nil
        }
    }

    /// Decides once per network whether the router is a Tenda, so other networks (a campus, a phone hotspot) are never probed again.
    static func detect(gateway: String) async -> Detection {
        guard let reply = await get(gateway, "goform/getProduct") else { return .unreachable }
        guard reply.status == 200, let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              json["product"] != nil else { return .other }
        return .tenda
    }

    static func fetch(gateway: String) async -> RouterStats? {
        async let status = get(gateway, "goform/GetRouterStatus")
        async let wan = get(gateway, "goform/getWanParameters")
        guard let s = await status, var stats = parseRouterStatus(s.data) else { return nil }
        if let w = await wan { stats.wanUptime = parseWanUptime(w.data) }
        return stats
    }

    static func parseRouterStatus(_ data: Data) -> RouterStats? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let wan = (json["wanInfo"] as? [[String: Any]])?.first
        var stats = RouterStats(clients: int(json["clientNum"]))
        stats.wanDownKBps = double(wan?["wanDownloadSpeed"])
        stats.wanUpKBps = double(wan?["wanUploadSpeed"])
        stats.wanStatus = wan?["wanStatus"].map { "\($0)" }
        return stats
    }

    static func parseWanUptime(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wan = (json["wanInfo"] as? [[String: Any]])?.first else { return nil }
        return int(wan["connectTime"])
    }

    // The firmware is inconsistent about numbers, sending some as JSON numbers and some as strings.
    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
