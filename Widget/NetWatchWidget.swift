import WidgetKit
import SwiftUI
import NetWatchCore
import NetWatchUI

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
        let samples = SampleStore().load(since: now.addingTimeInterval(-86_400))
        return [0, WidgetSnapshot.staleAfter + 20, 900].map { offset in
            let date = now.addingTimeInterval(offset)
            return NetWatchEntry(date: date, snapshot: .make(samples: samples, now: date))
        }
    }
}

struct NetWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetWatchEntry

    var body: some View {
        switch family {
        case .systemLarge:
            NetWatchLargeView(snapshot: entry.snapshot)
        default:
            NetWatchMediumView(snapshot: entry.snapshot)
        }
    }
}

struct NetWatchStatusWidget: Widget {
    let kind = "NetWatchStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NetWatchProvider()) { entry in
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
