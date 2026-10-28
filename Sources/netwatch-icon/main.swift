import SwiftUI
import AppKit
import NetWatchUI

// Usage: netwatch-icon <AppIcon.appiconset directory> [--legacy]
// Default art fills the whole square (the system rounds it). --legacy draws the old rounded tile with a margin and shadow.

/// Wi-Fi arcs over a pulse line: "the network, with a heartbeat".
struct Arc: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                 startAngle: .degrees(-135), endAngle: .degrees(-45), clockwise: false)
        return p
    }
}

struct Pulse: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.5), (0.34, 0.5), (0.43, 0.12), (0.53, 0.92), (0.62, 0.30), (0.68, 0.5), (1, 0.5)]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let c = CGPoint(x: rect.minX + rect.width * pt.0, y: rect.minY + rect.height * pt.1)
            i == 0 ? p.move(to: c) : p.addLine(to: c)
        }
        return p
    }
}

struct IconArt: View {
    let legacy: Bool

    private var background: LinearGradient {
        LinearGradient(colors: [Color(red: 0.13, green: 0.21, blue: 0.38), Color(red: 0.04, green: 0.06, blue: 0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var symbol: some View {
        ZStack {
            // Arcs fade outward, like signal strength.
            ForEach(Array([(150.0, 1.0), (265.0, 0.78), (380.0, 0.52)].enumerated()), id: \.offset) { _, a in
                Arc(radius: a.0)
                    .stroke(Theme.accent.opacity(a.1), style: StrokeStyle(lineWidth: 62, lineCap: .round))
                    .frame(width: 1024, height: 1024)
                    .offset(y: 120)
            }
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.95, blue: 0.68), Theme.ok], startPoint: .top, endPoint: .bottom))
                .frame(width: 112, height: 112)
                .shadow(color: Theme.ok.opacity(0.7), radius: 34)
                .offset(y: 120)
            Pulse()
                .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                .frame(width: 640, height: 150)
                .offset(y: 315)
        }
    }

    var body: some View {
        ZStack {
            if legacy {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(background)
                    .frame(width: 824, height: 824)
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
                symbol.scaleEffect(0.805)
            } else {
                Rectangle().fill(background)
                symbol
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(legacy: Bool) -> CGImage? {
    let r = ImageRenderer(content: IconArt(legacy: legacy))
    r.proposedSize = ProposedViewSize(width: 1024, height: 1024)
    r.scale = 1
    return r.cgImage
}

func resized(_ image: CGImage, to n: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let args = CommandLine.arguments.dropFirst()
guard let outDir = args.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: netwatch-icon <AppIcon.appiconset directory> [--legacy]")
    exit(64)
}
let dir = URL(fileURLWithPath: outDir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

await MainActor.run {
    guard let master = render(legacy: args.contains("--legacy")) else { print("render failed"); exit(1) }

    // macOS icon slots: point size and scale -> pixel size.
    let slots: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    var images: [[String: String]] = []
    for s in slots {
        let px = s.pt * s.scale
        let name = "icon_\(s.pt)x\(s.pt)\(s.scale == 2 ? "@2x" : "").png"
        guard let img = px == 1024 ? master : resized(master, to: px) else { continue }
        try? writePNG(img, to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(s.scale)x", "size": "\(s.pt)x\(s.pt)", "filename": name])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if let data = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: dir.appendingPathComponent("Contents.json"))
    }
    print("wrote \(images.count) icons to \(dir.path)")
}
