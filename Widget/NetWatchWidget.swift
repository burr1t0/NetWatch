import WidgetKit
import SwiftUI
import AppIntents
import NetWatchCore
import NetWatchUI

/// The period the user picked on the widget. Both the intent and the provider run in this extension, so its own
/// UserDefaults is enough to carry the choice from one to the other (no app group needed).
enum RangeStore {
    private static let key = "range"

    static var current: StatsRange {
        UserDefaults.standard.string(forKey: key).flatMap(StatsRange.init(rawValue:)) ?? .hour
    }

    static func set(_ range: StatsRange) {
        UserDefaults.standard.set(range.rawValue, forKey: key)
    }
}

/// Runs when a pill (hour / day / week) on the widget is pressed: remembers the choice and redraws the widget.
struct SetRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Период графика"
    static let description = IntentDescription("Показывает график за час, сутки или неделю.")

    @Parameter(title: "Период")
    var range: String

    init() {}

    init(range: StatsRange) {
        self.range = range.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let chosen = StatsRange(rawValue: range) { RangeStore.set(chosen) }
        WidgetCenter.shared.reloadTimelines(ofKind: NetWatchStatusWidget.kind)
        return .result()
    }
}

struct NetWatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NetWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetWatchEntry {
        NetWatchEntry(date: Date(), snapshot: Mock.snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (NetWatchEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries().first!)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetWatchEntry>) -> Void) {
        completion(Timeline(entries: entries(), policy: .after(Date().addingTimeInterval(120))))
    }

    /// The host app asks for a reload on every change, but if it is not running the widget must not keep claiming
    /// "all fine": later entries are built from the same log with a later `now`, so they flip to "no fresh data" on their own.
    private func entries() -> [NetWatchEntry] {
        let now = Date()
        let range = RangeStore.current
        let networks = NetworkRegistry().all()
        let samples = SampleStore().load(since: now.addingTimeInterval(-86_400))

        // Day and week come from the agent's quarter-hour rollups; the newest samples are folded in so the graph is not 15 minutes behind.
        var rollups: [Rollup] = []
        if range != .hour {
            let stored = RollupStore().load(since: now.addingTimeInterval(-range.duration - 3600))
            rollups = Rollups.merge(stored, with: Rollups.fresh(samples: samples, now: now, known: networks), keepSince: .distantPast)
        }

        return [0, WidgetSnapshot.staleAfter + 20, 900].map { offset in
            let date = now.addingTimeInterval(offset)
            return NetWatchEntry(date: date, snapshot: .make(samples: samples, now: date, networks: networks, range: range, rollups: rollups))
        }
    }
}

struct NetWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetWatchEntry

    /// Each period pill becomes a button that runs `SetRangeIntent` inside the widget itself.
    private let rangeButton: RangeButtonBuilder = { range, label in
        AnyView(Button(intent: SetRangeIntent(range: range)) { label }.buttonStyle(.plain))
    }

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                NetWatchLargeView(snapshot: entry.snapshot, rangeButton: rangeButton)
            default:
                NetWatchMediumView(snapshot: entry.snapshot, rangeButton: rangeButton)
            }
        }
        // A tap anywhere outside the pills opens the app's window (see AppDelegate).
        .widgetURL(URL(string: "netwatch://open"))
    }
}

struct NetWatchStatusWidget: Widget {
    static let kind = "NetWatchStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NetWatchProvider()) { entry in
            NetWatchWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
        }
        .configurationDisplayName("NetWatch")
        .description("Состояние домашней сети: где ломается — Wi-Fi, провайдер, DNS или VPN.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct NetWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetWatchStatusWidget()
    }
}
