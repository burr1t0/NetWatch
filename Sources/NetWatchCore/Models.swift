import Foundation

/// Result of a short burst of ICMP echoes to one host.
public struct Probe: Codable, Equatable, Sendable {
    public var sent: Int
    public var received: Int
    public var avgMs: Double?
    public var maxMs: Double?
    public var minMs: Double?

    public init(sent: Int, received: Int, avgMs: Double? = nil, maxMs: Double? = nil, minMs: Double? = nil) {
        self.sent = sent
        self.received = received
        self.avgMs = avgMs
        self.maxMs = maxMs
        self.minMs = minMs
    }

    public var loss: Double { sent == 0 ? 1 : 1 - Double(received) / Double(sent) }
}

public struct WiFiInfo: Codable, Equatable, Sendable {
    public var interface: String
    public var rssi: Int
    public var noise: Int
    public var txRateMbps: Double
    public var channel: Int
    public var band: String
    /// 5 GHz channels 52–64 and 100–144 share spectrum with radar, so the router may have to leave them abruptly.
    public var isDFS: Bool

    public init(interface: String, rssi: Int, noise: Int, txRateMbps: Double, channel: Int, band: String, isDFS: Bool) {
        self.interface = interface
        self.rssi = rssi
        self.noise = noise
        self.txRateMbps = txRateMbps
        self.channel = channel
        self.band = band
        self.isDFS = isDFS
    }
}

/// Traffic on the physical interface since the previous sample. Tells whether this Mac itself is filling the pipe.
public struct LinkStats: Codable, Equatable, Sendable {
    public var rxBps: Double
    public var txBps: Double
    public var rxErrors: Int
    public var txErrors: Int
    /// Bytes on awdl0 (AirDrop, Handoff, Continuity), which makes the Wi-Fi radio hop channels and adds latency.
    public var awdlBytes: Int

    public init(rxBps: Double, txBps: Double, rxErrors: Int = 0, txErrors: Int = 0, awdlBytes: Int = 0) {
        self.rxBps = rxBps
        self.txBps = txBps
        self.rxErrors = rxErrors
        self.txErrors = txErrors
        self.awdlBytes = awdlBytes
    }
}

/// State of the Mac itself that can throttle or delay networking.
public struct SystemStats: Codable, Equatable, Sendable {
    public var load1: Double
    public var cores: Int
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    public var lowPower: Bool
    public var onBattery: Bool

    public init(load1: Double, cores: Int, thermal: Int = 0, lowPower: Bool = false, onBattery: Bool = false) {
        self.load1 = load1
        self.cores = cores
        self.thermal = thermal
        self.lowPower = lowPower
        self.onBattery = onBattery
    }
}

/// Where the problem most likely is, ordered by `severity`.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    case ok, degraded, dns, vpn, isp, wifiOrRouter, noLink

    public var severity: Int {
        switch self {
        case .ok: return 0
        case .degraded: return 1
        case .dns: return 2
        case .vpn: return 3
        case .isp: return 4
        case .wifiOrRouter: return 5
        case .noLink: return 6
        }
    }

    public var title: String {
        switch self {
        case .ok: return "ОК"
        case .degraded: return "Деградация"
        case .dns: return "DNS"
        case .vpn: return "VPN"
        case .isp: return "Провайдер"
        case .wifiOrRouter: return "Wi-Fi/роутер"
        case .noLink: return "Нет сети"
        }
    }
}

/// One measurement round. Everything except `vpnHttpMs` is bound to the physical interface, so a VPN cannot hide or fake it.
public struct Sample: Codable, Sendable {
    public var t: Date
    public var iface: String?
    public var gateway: String?
    public var vpn: Bool
    /// ICMP to the router.
    public var gw: Probe?
    /// ICMP to 1.1.1.1 and 8.8.8.8 over the physical interface, bypassing the VPN.
    public var direct: Probe?
    public var direct2: Probe?
    public var dnsServer: String?
    public var dnsMs: Double?
    public var tcpDirectMs: Double?
    /// Full HTTPS request over the default route, i.e. what apps experience (through the VPN when it is on).
    public var httpMs: Double?
    public var wifi: WiFiInfo?
    public var verdict: Verdict
    // Context for telling causes apart. All optional, so logs written before they existed still decode.
    public var link: LinkStats?
    public var system: SystemStats?
    /// 20 echoes to the router 100 ms apart, taken only during a problem; -1 marks a lost echo.
    /// Steadily high values mean congestion, isolated peaks mean something periodic (scans, AWDL).
    public var gwBurst: [Int]?
    /// Heaviest network processes at the time of a problem, e.g. "Telegram 1.3 МБ/с".
    public var talkers: [String]?
    /// Which network this was measured on, so a Mac that moves between campuses does not mix them up.
    public var network: NetworkKey?
    /// Set when this network is known to drop ICMP to the router / to the internet. Such probes say nothing either way.
    public var gwIcmpFiltered: Bool?
    public var externalIcmpFiltered: Bool?

    public init(
        t: Date = Date(), iface: String? = nil, gateway: String? = nil, vpn: Bool = false,
        gw: Probe? = nil, direct: Probe? = nil, direct2: Probe? = nil,
        dnsServer: String? = nil, dnsMs: Double? = nil, tcpDirectMs: Double? = nil, httpMs: Double? = nil,
        wifi: WiFiInfo? = nil, verdict: Verdict = .ok,
        link: LinkStats? = nil, system: SystemStats? = nil, gwBurst: [Int]? = nil, talkers: [String]? = nil,
        network: NetworkKey? = nil, gwIcmpFiltered: Bool? = nil, externalIcmpFiltered: Bool? = nil
    ) {
        self.network = network
        self.gwIcmpFiltered = gwIcmpFiltered
        self.externalIcmpFiltered = externalIcmpFiltered
        self.link = link
        self.system = system
        self.gwBurst = gwBurst
        self.talkers = talkers
        self.t = t
        self.iface = iface
        self.gateway = gateway
        self.vpn = vpn
        self.gw = gw
        self.direct = direct
        self.direct2 = direct2
        self.dnsServer = dnsServer
        self.dnsMs = dnsMs
        self.tcpDirectMs = tcpDirectMs
        self.httpMs = httpMs
        self.wifi = wifi
        self.verdict = verdict
    }
}

public extension Sample {
    /// Best (lowest) average RTT to the internet over the physical interface. Where ICMP is dropped, the TCP handshake time stands in.
    var directRttMs: Double? {
        [direct?.avgMs, direct2?.avgMs].compactMap { $0 }.min() ?? tcpDirectMs
    }

    var summaryLine: String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0fms", $0) } ?? "—" }
        func probe(_ p: Probe?) -> String {
            guard let p else { return "—" }
            if p.received == 0 { return "LOSS" }
            return ms(p.avgMs) + (p.loss > 0 ? " (\(Int((p.loss * 100).rounded()))% loss)" : "")
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var parts = [
            f.string(from: t),
            verdict.title.padding(toLength: 13, withPad: " ", startingAt: 0),
            "gw \(probe(gw))",
            "1.1.1.1 \(probe(direct))",
            "8.8.8.8 \(probe(direct2))",
            "dns \(ms(dnsMs))",
            "http \(ms(httpMs))\(vpn ? " [vpn]" : "")",
        ]
        if let w = wifi { parts.append("wifi \(w.rssi)dBm ch\(w.channel)\(w.isDFS ? " DFS" : "")") }
        if let l = link { parts.append(String(format: "↓%.1f ↑%.1f МБ/с", l.rxBps / 1e6, l.txBps / 1e6)) }
        return parts.joined(separator: "  ")
    }
}
