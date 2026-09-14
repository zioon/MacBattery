// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MacBattery",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // C 目标：AppleSMC 读取（复用经验证的 C 实现，保证 80 字节协议帧布局）。
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge"
        ),
        .executableTarget(
            name: "MacBattery",
            dependencies: ["SMCBridge"],
            path: "Sources/MacBattery"
        )
    ]
)