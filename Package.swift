// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerMate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PowerMate",
            path: "Sources/PowerMate"
        )
    ]
)
