// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS("15.0")],
    targets: [
        // C core: parallel scanner, treemap layout, cushion renderer.
        .target(
            name: "CScan",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        // Headless scanner for benchmarking and quick answers in a terminal.
        .executableTarget(name: "dmscan", dependencies: ["CScan"]),
        // The app.
        .executableTarget(name: "DiskMap", dependencies: ["CScan"]),
        .testTarget(name: "CScanTests", dependencies: ["CScan"]),
    ]
)
