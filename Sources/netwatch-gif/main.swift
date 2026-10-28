import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import NetWatchCore
import NetWatchUI

// Usage: netwatch-gif <output directory>
// Draws the widget with synthetic data and writes the animations used in the README.

/// The widget on a dark backdrop, like a screenshot of the desktop. A solid backdrop also avoids the ragged edges
/// that GIF's one-bit transparency would give the rounded corners.
struct Frame<Content: View>: View {
    let size: CGSize
    let content: Content

    init(size: CGSize, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    var body: some View {
        WidgetFrame { content }
            .frame(width: size.width, height: size.height)
            .padding(22)
            .background(Color(red: 0.035, green: 0.045, blue: 0.075))
    }
}

@MainActor
func render<V: View>(_ view: V) -> CGImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    return renderer.cgImage
}

func writeGIF(_ frames: [(image: CGImage, seconds: Double)], to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return false }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in frames {
        CGImageDestinationAddImage(destination, frame.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.seconds]] as CFDictionary)
    }
    return CGImageDestinationFinalize(destination)
}

func fileSize(_ url: URL) -> String {
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

// A fixed moment in a fixed time zone: the clock times inside the animations say nothing about when or where they were
// made, and the same input always gives the same files.
setenv("TZ", "UTC", 1)
tzset()
NSTimeZone.resetSystemTimeZone()
let now = ISO8601DateFormatter().date(from: "2026-03-12T18:40:00Z")!

guard let outPath = CommandLine.arguments.dropFirst().first else {
    print("usage: netwatch-gif <output directory>")
    exit(64)
}
let outDir = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

await MainActor.run {
    let large = WidgetSizes.large
    let medium = WidgetSizes.medium

    // 1. The period switch: hour, day, week.
    var periods: [(CGImage, Double)] = []
    for range in StatsRange.allCases {
        let snapshot = Mock.snapshot(now: now, days: 7, range: range)
        if let image = render(Frame(size: large) { NetWatchLargeView(snapshot: snapshot) }) { periods.append((image, 1.9)) }
    }

    // 2 and 3. A problem develops and clears: fine, slow, nothing gets through the router, fine again.
    // Absolute-time outages scroll to the left as time advances, like the real graph.
    let start = now.addingTimeInterval(-25 * 60)
    let step: TimeInterval = 90
    let outages = [
        Mock.Outage(start: start.addingTimeInterval(5 * step), end: start.addingTimeInterval(8 * step), verdict: .degraded),
        Mock.Outage(start: start.addingTimeInterval(8 * step), end: start.addingTimeInterval(11 * step), verdict: .wifiOrRouter),
    ]
    var mediumStory: [(CGImage, Double)] = []
    var largeStory: [(CGImage, Double)] = []
    for k in 0..<16 {
        let at = start.addingTimeInterval(Double(k) * step + 60)
        let snapshot = Mock.snapshot(now: at, events: false, outages: outages)
        // Pause on the interesting states, move quickly through the rest.
        let seconds: Double = snapshot.status == .ok ? 0.55 : 0.9
        if let image = render(Frame(size: medium) { NetWatchMediumView(snapshot: snapshot) }) { mediumStory.append((image, seconds)) }
        if let image = render(Frame(size: large) { NetWatchLargeView(snapshot: snapshot) }) { largeStory.append((image, seconds)) }
    }

    for (name, frames) in [("widget-periods", periods), ("widget-incident-medium", mediumStory), ("widget-incident-large", largeStory)] {
        let url = outDir.appendingPathComponent("\(name).gif")
        let ok = writeGIF(frames.map { (image: $0.0, seconds: $0.1) }, to: url)
        print(ok ? "wrote \(url.lastPathComponent): \(frames.count) frames, \(fileSize(url))" : "failed: \(name)")
    }
}
