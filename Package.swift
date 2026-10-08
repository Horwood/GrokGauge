// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GrokGauge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GrokGauge", targets: ["GrokGauge"]),
    ],
    targets: [
        // Pure Foundation logic: auth file reading, the billing request, parsing.
        .target(name: "GrokGaugeCore"),
        // The menu bar app (AppKit + SwiftUI) and the --print-usage debug CLI.
        .executableTarget(
            name: "GrokGauge",
            dependencies: ["GrokGaugeCore"]
        ),
        .testTarget(
            name: "GrokGaugeCoreTests",
            dependencies: ["GrokGaugeCore"]
        ),
    ]
)
