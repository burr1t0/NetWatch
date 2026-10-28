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
    ],
    targets: [
        .target(name: "NetWatchCore"),
        .target(name: "NetWatchUI", dependencies: ["NetWatchCore"]),
        .executableTarget(name: "netwatchd", dependencies: ["NetWatchCore"]),
        // Renders the widget views to PNG, so layout can be checked without Notification Center.
        .executableTarget(name: "netwatch-preview", dependencies: ["NetWatchCore", "NetWatchUI"]),
        .testTarget(name: "NetWatchCoreTests", dependencies: ["NetWatchCore"]),
    ]
)
