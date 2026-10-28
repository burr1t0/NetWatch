// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NetWatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetWatchCore", targets: ["NetWatchCore"]),
        .library(name: "NetWatchUI", targets: ["NetWatchUI"]),
        .executable(name: "netwatchd", targets: ["netwatchd"]),
        .executable(name: "netwatch-preview", targets: ["netwatch-preview"]),
        .executable(name: "netwatch-icon", targets: ["netwatch-icon"]),
        .executable(name: "netwatch-gif", targets: ["netwatch-gif"]),
    ],
    targets: [
        .target(name: "NetWatchCore"),
        .target(name: "NetWatchUI", dependencies: ["NetWatchCore"]),
        .executableTarget(name: "netwatchd", dependencies: ["NetWatchCore"]),
        // Renders the widget views to PNG, so layout can be checked without Notification Center.
        .executableTarget(name: "netwatch-preview", dependencies: ["NetWatchCore", "NetWatchUI"]),
        // Draws the app icon, so the artwork is reproducible from code instead of a binary nobody can edit.
        .executableTarget(name: "netwatch-icon", dependencies: ["NetWatchUI"]),
        // Renders the README animations from synthetic data, so no screen recording (and nothing personal) is involved.
        .executableTarget(name: "netwatch-gif", dependencies: ["NetWatchCore", "NetWatchUI"]),
        .testTarget(name: "NetWatchCoreTests", dependencies: ["NetWatchCore"]),
    ]
)
