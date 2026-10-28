import SwiftUI
import NetWatchCore

/// Medium widget: status, four key numbers and the last hour.
public struct NetWatchMediumView: View {
    private let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            StatusHeader(s: snapshot)
            MetricsRow(s: snapshot)
            HourGraph(s: snapshot)
        }
    }
}

/// Large widget: everything from the medium one plus both latency lines, Wi-Fi details and recent incidents.
public struct NetWatchLargeView: View {
    private let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader(s: snapshot)
            MetricsRow(s: snapshot)
            HourGraph(s: snapshot, showGateway: true)
                .frame(height: 118)
            Rectangle().fill(Theme.faint).frame(height: 1)
            WifiRow(wifi: snapshot.latest?.wifi)
            IncidentsList(incidents: Array(snapshot.incidents.prefix(3)))
            Spacer(minLength: 0)
        }
    }
}
