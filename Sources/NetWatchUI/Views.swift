import SwiftUI
import NetWatchCore

/// Medium widget: status with the period switch, four key numbers and the graph for the chosen period.
/// `rangeButton` makes the period switch tappable; the widget and the app window supply it, previews leave it out.
public struct NetWatchMediumView: View {
    private let snapshot: WidgetSnapshot
    private let rangeButton: RangeButtonBuilder?

    public init(snapshot: WidgetSnapshot, rangeButton: RangeButtonBuilder? = nil) {
        self.snapshot = snapshot
        self.rangeButton = rangeButton
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StatusHeader(s: snapshot, rangeButton: rangeButton)
            MetricsRow(s: snapshot)
            HourGraph(s: snapshot)
        }
    }
}

/// Large widget: everything from the medium one plus both latency lines, Wi-Fi details and recent incidents.
public struct NetWatchLargeView: View {
    private let snapshot: WidgetSnapshot
    private let rangeButton: RangeButtonBuilder?

    public init(snapshot: WidgetSnapshot, rangeButton: RangeButtonBuilder? = nil) {
        self.snapshot = snapshot
        self.rangeButton = rangeButton
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader(s: snapshot, rangeButton: rangeButton)
            MetricsRow(s: snapshot)
            HourGraph(s: snapshot, showGateway: true)
                .frame(height: 118)
            Rectangle().fill(Theme.faint).frame(height: 1)
            WifiRow(wifi: snapshot.latest?.wifi)
            IncidentsList(incidents: Array(snapshot.incidents.prefix(3)), range: snapshot.range, networkName: snapshot.networkName)
            Spacer(minLength: 0)
        }
    }
}
