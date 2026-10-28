import Foundation

/// How far back the graph looks. A graph always has `bucketCount` slots, so a longer range means coarser slots.
public enum StatsRange: String, Codable, CaseIterable, Sendable {
    case hour, day, week

    public var title: String {
        switch self {
        case .hour: return "Час"
        case .day: return "Сутки"
        case .week: return "Неделя"
        }
    }

    /// Short phrase for "over the last ...".
    public var label: String {
        switch self {
        case .hour: return "за час"
        case .day: return "за сутки"
        case .week: return "за неделю"
        }
    }

    public var axisStart: String {
        switch self {
        case .hour: return "60 мин назад"
        case .day: return "24 ч назад"
        case .week: return "7 дней назад"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 604_800
        }
    }

    public var bucketSeconds: TimeInterval {
        switch self {
        case .hour: return 60
        case .day: return 900
        case .week: return 7200
        }
    }

    public var bucketCount: Int { Int(duration / bucketSeconds) }
}
