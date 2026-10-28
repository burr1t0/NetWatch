import SwiftUI
import WidgetKit
import NetWatchCore

public enum Theme {
    public static let bgTop = Color(red: 0.07, green: 0.10, blue: 0.18)
    public static let bgBottom = Color(red: 0.03, green: 0.05, blue: 0.10)
    public static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public static let text = Color.white.opacity(0.94)
    public static let muted = Color.white.opacity(0.55)
    public static let faint = Color.white.opacity(0.10)

    public static let ok = Color(red: 0.30, green: 0.86, blue: 0.56)
    public static let warn = Color(red: 1.0, green: 0.76, blue: 0.28)
    public static let bad = Color(red: 1.0, green: 0.38, blue: 0.38)
    public static let unknown = Color.white.opacity(0.35)
    public static let accent = Color(red: 0.42, green: 0.72, blue: 1.0)
}

public extension Verdict {
    var tint: Color { tint(fullColor: true) }

    /// In monochrome widget modes hue is lost but opacity survives, so severity is also encoded as brightness.
    func tint(fullColor: Bool) -> Color {
        switch self {
        case .ok: return fullColor ? Theme.ok : Color.white.opacity(0.4)
        case .degraded, .dns, .vpn: return fullColor ? Theme.warn : Color.white.opacity(0.75)
        case .isp, .wifiOrRouter, .noLink: return fullColor ? Theme.bad : Color.white
        }
    }

    /// A shape per state, so the status reads without color too.
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .degraded, .dns, .vpn: return "exclamationmark.triangle.fill"
        case .isp, .wifiOrRouter, .noLink: return "xmark.octagon.fill"
        }
    }
}

private struct ForceMonochromeKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Lets previews imitate the monochrome widget styles, which cannot be set through `widgetRenderingMode`.
    var forceMonochrome: Bool {
        get { self[ForceMonochromeKey.self] }
        set { self[ForceMonochromeKey.self] = newValue }
    }
}

/// Whether the widget is drawn in full color (Notification Center may switch to accented / monochrome styles).
struct RenderStyle: DynamicProperty {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.forceMonochrome) private var mono

    var full: Bool { mode == .fullColor && !mono }
}

public enum WidgetSizes {
    /// Point sizes of the system medium and large widgets on macOS.
    public static let medium = CGSize(width: 364, height: 170)
    public static let large = CGSize(width: 364, height: 382)
}

/// Stand-in for the widget container when a view is shown outside WidgetKit (settings window, PNG previews).
public struct WidgetFrame<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}
