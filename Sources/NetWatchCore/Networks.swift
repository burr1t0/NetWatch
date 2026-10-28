import Foundation
import CryptoKit

/// Identifies one network by its router. Hashed, so logs and reports do not carry the router's MAC address.
public struct NetworkKey: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var gateway: String

    public init(id: String, gateway: String) {
        self.id = id
        self.gateway = gateway
    }

    public static func make(gateway: String, mac: String?) -> NetworkKey {
        let digest = SHA256.hash(data: Data("\(gateway)|\(mac ?? "")".utf8))
        return NetworkKey(id: digest.prefix(4).map { String(format: "%02x", $0) }.joined(), gateway: gateway)
    }
}

/// A network the Mac has been on, with the name the user sees and what has been learned about it.
public struct KnownNetwork: Codable, Equatable, Sendable {
    public var id: String
    public var gateway: String
    public var name: String
    public var customName: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    /// Learned: this network never answers ICMP to the router, so a silent router is not a problem here.
    public var gatewayIcmpFiltered: Bool?
    /// Learned: ICMP to the internet is dropped (typical for campus and corporate networks); TCP and HTTPS are used instead.
    public var externalIcmpFiltered: Bool?
    /// "tenda" when the router's status page was recognised, "other" when it answered with something else; nil until checked.
    public var router: String?

    public init(id: String, gateway: String, name: String, customName: Bool = false, firstSeen: Date, lastSeen: Date,
                gatewayIcmpFiltered: Bool? = nil, externalIcmpFiltered: Bool? = nil, router: String? = nil) {
        self.id = id
        self.gateway = gateway
        self.name = name
        self.customName = customName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.gatewayIcmpFiltered = gatewayIcmpFiltered
        self.externalIcmpFiltered = externalIcmpFiltered
        self.router = router
    }
}

/// Known networks, kept in `networks.json` next to the sample log so the agent, the app and the widget all see the same names.
public final class NetworkRegistry {
    private let url: URL
    private let queue = DispatchQueue(label: "netwatch.networks")

    public init(dir: URL = SampleStore.defaultDir) {
        url = dir.appendingPathComponent("networks.json")
    }

    public static func autoName(gateway: String) -> String {
        // 172.20.10.0/28 is the range Apple's Personal Hotspot always hands out.
        gateway.hasPrefix("172.20.10.") ? "Раздача iPhone" : "Сеть \(gateway)"
    }

    public func all() -> [KnownNetwork] {
        queue.sync { load() }
    }

    /// Records that the Mac is on this network now and returns what is known about it, adding it on first sight.
    @discardableResult
    public func observe(_ key: NetworkKey, at date: Date = Date()) -> KnownNetwork {
        queue.sync {
            var list = load()
            if let i = list.firstIndex(where: { $0.id == key.id }) {
                if date.timeIntervalSince(list[i].lastSeen) > 600 {
                    list[i].lastSeen = date
                    save(list)
                }
                return list[i]
            }
            let network = KnownNetwork(id: key.id, gateway: key.gateway, name: uniqueName(Self.autoName(gateway: key.gateway), in: list),
                                       customName: false, firstSeen: date, lastSeen: date)
            list.append(network)
            save(list)
            return network
        }
    }

    public func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id: id) {
            $0.name = trimmed
            $0.customName = true
        }
    }

    public func update(id: String, _ change: (inout KnownNetwork) -> Void) {
        queue.sync {
            var list = load()
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[i])
            save(list)
        }
    }

    private func uniqueName(_ base: String, in list: [KnownNetwork]) -> String {
        var name = base
        var n = 2
        while list.contains(where: { $0.name == name }) {
            name = "\(base) (\(n))"
            n += 1
        }
        return name
    }

    private func load() -> [KnownNetwork] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KnownNetwork].self, from: data)) ?? []
    }

    private func save(_ list: [KnownNetwork]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}

public enum Networks {
    /// The network of each sample, oldest first.
    /// - A sample without a router (link down) inherits the previous one: losing the link while on a network is that network's incident.
    /// - Old samples written before networks were tracked have no key; they are matched by router IP when exactly one known network has it.
    public static func ids(for sorted: [Sample], known: [KnownNetwork]) -> [String?] {
        var current: String?
        return sorted.map { s in
            if let n = s.network {
                current = n.id
            } else if let gw = s.gateway {
                let matches = known.filter { $0.gateway == gw }
                current = matches.count == 1 ? matches[0].id : "gw:\(gw)"
            }
            return current
        }
    }

    /// Samples split by network, the most recently active network first.
    public static func partition(_ samples: [Sample], known: [KnownNetwork]) -> [(id: String, samples: [Sample])] {
        let sorted = samples.sorted { $0.t < $1.t }
        let ids = Self.ids(for: sorted, known: known)
        var order: [String] = []
        var groups: [String: [Sample]] = [:]
        for (s, id) in zip(sorted, ids) {
            guard let id else { continue }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(s)
        }
        return order.map { (id: $0, samples: groups[$0] ?? []) }
            .sorted { ($0.samples.last?.t ?? .distantPast) > ($1.samples.last?.t ?? .distantPast) }
    }

    /// Only the network the Mac is on now (that of the newest sample). Without any network information, everything is returned.
    public static func currentOnly(_ sorted: [Sample], known: [KnownNetwork]) -> (samples: [Sample], id: String?) {
        let ids = Self.ids(for: sorted, known: known)
        guard let current = ids.last ?? nil else { return (sorted, nil) }
        return (zip(sorted, ids).filter { $0.1 == current }.map { $0.0 }, current)
    }

    public static func name(for id: String, known: [KnownNetwork]) -> String {
        if let k = known.first(where: { $0.id == id }) { return k.name }
        return id.hasPrefix("gw:") ? "Сеть \(id.dropFirst(3))" : "Сеть \(id)"
    }

    public static func gateway(for id: String, known: [KnownNetwork], samples: [Sample]) -> String? {
        known.first(where: { $0.id == id })?.gateway
            ?? samples.last?.network?.gateway
            ?? samples.last?.gateway
    }
}
