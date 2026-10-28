import SwiftUI
import NetWatchCore

/// Wraps a period label in whatever makes it tappable. Only the widget can do that (it needs an App Intent button),
/// so the shared views take it as a closure; without one the pills are just a display.
public typealias RangeButtonBuilder = (StatsRange, AnyView) -> AnyView

enum Fmt {
    static func when(_ d: Date, range: StatsRange) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = range == .week ? "E HH:mm" : "HH:mm"
        return f.string(from: d)
    }

    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 10 ? String(format: "%.1f мс", v) : String(format: "%.0f мс", v)
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(max(s, 1)) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \(s % 3600 / 60) мин"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: Header

struct StatusHeader: View {
    private let style = RenderStyle()
    let s: WidgetSnapshot
    var rangeButton: RangeButtonBuilder?
    private var color: Color { s.status?.tint(fullColor: style.full) ?? Theme.unknown }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: s.status?.symbol ?? "questionmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .shadow(color: style.full ? color.opacity(0.7) : .clear, radius: 4)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(s.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            // The period switch lives here, above the graph's data, so it never hides a spike.
            VStack(alignment: .trailing, spacing: 3) {
                if let a = s.availability {
                    Text(String(format: "%.1f%%", a * 100))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(style.full ? (a > 0.99 ? Theme.ok : (a > 0.95 ? Theme.warn : Theme.bad)) : Theme.text)
                }
                RangePills(selected: s.range, button: rangeButton)
            }
        }
    }
}

// MARK: Metrics

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricsRow: View {
    let s: WidgetSnapshot

    var body: some View {
        let l = s.latest
        HStack(alignment: .top, spacing: 8) {
            Metric(title: "Роутер", value: Fmt.ms(l?.gw?.avgMs))
            Metric(title: "Интернет", value: Fmt.ms(l?.directRttMs))
            Metric(title: "DNS", value: Fmt.ms(l?.dnsMs))
            Metric(title: l?.vpn == true ? "Через VPN" : "HTTPS", value: Fmt.ms(l?.httpMs))
        }
        .opacity(s.isStale ? 0.4 : 1)
    }
}

// MARK: Hour graph

struct LineShape: Shape {
    let values: [Double?]
    let maxY: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var penDown = false
        for (i, v) in values.enumerated() {
            guard let v else { penDown = false; continue }
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
            let y = rect.maxY - rect.height * CGFloat(min(v, maxY) / maxY)
            let pt = CGPoint(x: x, y: y)
            if penDown {
                p.addLine(to: pt)
            } else {
                // A zero-length segment still draws a dot with round caps, so isolated samples stay visible.
                p.move(to: pt)
                p.addLine(to: pt)
                penDown = true
            }
        }
        return p
    }
}

struct StatusStrip: View {
    private let style = RenderStyle()
    let buckets: [GraphBucket]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(buckets.indices, id: \.self) { i in
                // Without color a problem minute is taller, so the strip still shows where it was bad.
                let v = buckets[i].verdict
                let bad = (v?.severity ?? 0) > 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(v?.tint(fullColor: style.full) ?? Theme.faint)
                    .frame(maxHeight: style.full || bad ? .infinity : 2.5)
            }
        }
    }
}

struct HourGraph: View {
    private let style = RenderStyle()
    let s: WidgetSnapshot
    var showGateway = false

    private var lineColor: Color { style.full ? Theme.accent : Color.white.opacity(0.95) }
    private var gatewayColor: Color { style.full ? Theme.muted : Color.white.opacity(0.4) }

    private var maxY: Double {
        max(60, min(300, (s.buckets.compactMap { $0.rttMs }.max() ?? 0) * 1.25))
    }

    private var hasData: Bool { s.buckets.contains { $0.rttMs != nil || $0.verdict != nil } }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(Theme.faint).frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                }
                if hasData {
                    if showGateway {
                        LineShape(values: s.buckets.map { $0.gwMs }, maxY: maxY)
                            .stroke(gatewayColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: style.full ? [] : [3, 2]))
                    }
                    LineShape(values: s.buckets.map { $0.rttMs }, maxY: maxY)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    Text("\(Int(maxY)) мс")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("Нет данных за период")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            StatusStrip(buckets: s.buckets).frame(height: 5)
            HStack {
                Text(s.range.axisStart)
                Spacer()
                if showGateway {
                    Label("интернет", systemImage: "minus").labelStyle(LegendStyle(color: lineColor))
                    Label("роутер", systemImage: "minus").labelStyle(LegendStyle(color: gatewayColor))
                    Spacer()
                } else if let name = s.networkName {
                    // The medium widget has no room for a legend, so the empty middle of the axis names the network.
                    Text(name).lineLimit(1)
                    Spacer()
                }
                Text("сейчас")
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.muted)
        }
    }
}

/// Hour / day / week switch. Inside the widget each pill is an App Intent button; elsewhere it only shows the selection.
struct RangePills: View {
    private let style = RenderStyle()
    let selected: StatsRange
    let button: RangeButtonBuilder?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(StatsRange.allCases, id: \.self) { range in
                let label = AnyView(
                    Text(range.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(range == selected ? Theme.text : Theme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(range == selected ? Color.white.opacity(style.full ? 0.20 : 0.28) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                )
                if let button { button(range, label) } else { label }
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.40), in: Capsule())
    }
}

struct LegendStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 2)
            configuration.title
        }
    }
}

// MARK: Large-only blocks

struct WifiRow: View {
    let wifi: WiFiInfo?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            if let w = wifi {
                Text("\(w.band) · канал \(w.channel)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                if w.isDFS {
                    Text("DFS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.warn.opacity(0.16), in: Capsule())
                }
                Spacer()
                Text("\(w.rssi) dBm · \(Int(w.txRateMbps)) Мбит/с")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            } else {
                Text("Wi-Fi: нет данных")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
        }
    }
}

/// What the router says about itself: how much it is moving, how many devices are on it, how long the provider link has held.
/// Shown only when the router can be read (Tenda), so on other networks the widget simply has one row less.
struct RouterRow: View {
    let stats: RouterStats

    private func speed(_ kbps: Double?) -> String {
        guard let kbps else { return "—" }
        return kbps >= 1024 ? String(format: "%.1f МБ/с", kbps / 1024) : String(format: "%.0f КБ/с", kbps)
    }

    private func held(_ seconds: Int) -> String {
        seconds >= 86_400 ? "\(seconds / 86_400) дн" : (seconds >= 3600 ? "\(seconds / 3600) ч \(seconds % 3600 / 60) мин" : "\(seconds / 60) мин")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.router")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text("↓ \(speed(stats.wanDownKBps))  ↑ \(speed(stats.wanUpKBps))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Spacer()
            Text(rightSide)
                .font(.system(size: 11))
                .foregroundStyle(stats.reconnected == true ? Theme.warn : Theme.muted)
                .lineLimit(1)
        }
    }

    private var rightSide: String {
        var parts: [String] = []
        if let c = stats.clients { parts.append("устр.: \(c)") }
        if let u = stats.wanUptime { parts.append("связь \(held(u))") }
        return parts.joined(separator: " · ")
    }
}

struct IncidentsList: View {
    private let style = RenderStyle()
    let incidents: [Incident]
    var range: StatsRange = .hour
    var networkName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(range == .week ? "Инциденты за неделю" : "Инциденты за 24 часа")
                Spacer()
                if let networkName { Text(networkName).lineLimit(1) }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.muted)
            if incidents.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Text("Проблем не было")
                        .foregroundStyle(Theme.text)
                }
                .font(.system(size: 11))
            } else {
                ForEach(incidents.indices, id: \.self) { i in
                    let inc = incidents[i]
                    HStack(spacing: 7) {
                        Text(Fmt.when(inc.start, range: range))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .frame(width: range == .week ? 64 : 38, alignment: .leading)
                        Image(systemName: inc.verdict.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(inc.verdict.tint(fullColor: style.full))
                            .frame(width: 11)
                        Text(inc.verdict.title)
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text(Fmt.duration(inc.duration))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}
