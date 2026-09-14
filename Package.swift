// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MacBattery",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "MacBattery",
            path: "Sources/MacBattery"
        )
    ]
)