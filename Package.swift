// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenRecast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenRecast",
            path: "Sources/OpenRecast"
        )
    ]
)
