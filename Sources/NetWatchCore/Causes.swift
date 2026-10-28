import Foundation

/// Why the router answered slowly. Only things this Mac can see; "external" means none of them applies.
public enum SpikeCause: String, Codable, CaseIterable, Sendable {
    case ownTraffic, awdl, powerSaving, cpuLoad, congestion, bursts, external

    public var title: String {
        switch self {
        case .ownTraffic: return "Свой трафик Mac (>2 МБ/с)"
        case .awdl: return "Активность AWDL (AirDrop/Handoff)"
        case .powerSaving: return "Энергосбережение или перегрев Mac"
        case .cpuLoad: return "Высокая загрузка процессора"
        case .congestion: return "Ровно высокая задержка (затор в роутере или эфире)"
        case .bursts: return "Периодические всплески (сканы Wi-Fi, AWDL)"
        case .external: return "Ничего локального не найдено (роутер, другие устройства, радиоэфир)"
        }
    }
}

public enum Causes {
    public static let heavyTrafficBps = 2_000_000.0
    public static let awdlBytes = 10_000

    /// The router itself is slow, so the problem sits on the Mac–router leg or in the router.
    public static func isLocalSpike(_ s: Sample) -> Bool {
        (s.gw?.avgMs ?? 0) > 30
    }

    /// Shape of the 20-echo burst: nil when it looks calm or is too short to judge.
    public static func burstPattern(_ series: [Int]) -> SpikeCause? {
        let ok = series.filter { $0 >= 0 }
        guard ok.count >= 8 else { return nil }
        let median = ok.sorted()[ok.count / 2]
        if median > 30 { return .congestion }
        let peaks = ok.filter { $0 > max(30, median * 4) }.count
        return peaks >= 2 ? .bursts : nil
    }

    /// Causes visible in this sample. Empty when the sample carries no context at all (older log entries).
    public static func causes(for s: Sample) -> [SpikeCause] {
        guard s.link != nil || s.system != nil else { return [] }
        var result: [SpikeCause] = []
        if let l = s.link {
            if l.rxBps + l.txBps > heavyTrafficBps { result.append(.ownTraffic) }
            if l.awdlBytes > awdlBytes { result.append(.awdl) }
        }
        if let y = s.system {
            if y.lowPower || y.thermal >= 2 { result.append(.powerSaving) }
            if y.load1 > Double(y.cores) * 0.8 { result.append(.cpuLoad) }
        }
        if let b = s.gwBurst, let pattern = burstPattern(b) { result.append(pattern) }
        return result.isEmpty ? [.external] : result
    }
}
