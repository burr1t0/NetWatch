import SwiftUI
import AppKit
import NetWatchCore
import NetWatchUI

// Usage: netwatch-preview [output-dir]
// Writes PNGs of the widget views, one set from the real log and one from synthetic data.
let outDir = CommandLine.arguments.dropFirst().first ?? "."

@MainActor
func save<V: View>(_ view: V, size: CGSize, name: String) {
    let framed = WidgetFrame { view }.frame(width: size.width, height: size.height)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("render failed: \(name)")
        return
    }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("saved \(outDir)/\(name).png")
}

await MainActor.run {
    let now = Date()
    let real = WidgetSnapshot.make(samples: SampleStore().load(since: now.addingTimeInterval(-86_400)), now: now)
    save(NetWatchMediumView(snapshot: real), size: WidgetSizes.medium, name: "medium-real")
    save(NetWatchLargeView(snapshot: real), size: WidgetSizes.large, name: "large-real")

    let ok = Mock.snapshot(now: now)
    save(NetWatchMediumView(snapshot: ok), size: WidgetSizes.medium, name: "medium-mock-ok")
    save(NetWatchLargeView(snapshot: ok), size: WidgetSizes.large, name: "large-mock-ok")

    let bad = Mock.snapshot(now: now, current: .wifiOrRouter)
    save(NetWatchMediumView(snapshot: bad), size: WidgetSizes.medium, name: "medium-mock-bad")
    save(NetWatchLargeView(snapshot: Mock.snapshot(now: now, current: .degraded)), size: WidgetSizes.large, name: "large-mock-degraded")

    let stale = WidgetSnapshot.make(samples: [], now: now)
    save(NetWatchMediumView(snapshot: stale), size: WidgetSizes.medium, name: "medium-nodata")

    // Notification Center can strip the hue; this imitates it (grayscale + the monochrome code path).
    save(NetWatchLargeView(snapshot: Mock.snapshot(now: now, current: .degraded)).environment(\.forceMonochrome, true).saturation(0),
         size: WidgetSizes.large, name: "large-mono-degraded")
    save(NetWatchMediumView(snapshot: bad).environment(\.forceMonochrome, true).saturation(0),
         size: WidgetSizes.medium, name: "medium-mono-bad")
}
