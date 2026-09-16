// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MacBattery",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // 纯逻辑层（U-09）：无 AppKit / IOKit 依赖，可独立单测。
        // 约定：本目录内禁止 import AppKit / IOKit —— 破坏这条约定就会让测试失去意义。
        .target(
            name: "MacBatteryCore",
            path: "Sources/MacBatteryCore"
        ),
        // C 目标：AppleSMC 读取（复用经验证的 C 实现，保证 80 字节协议帧布局）。
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge"
        ),
        .executableTarget(
            name: "MacBatteryHelper",
            dependencies: ["SMCBridge"],
            path: "Sources/MacBatteryHelper"
        ),
        .executableTarget(
            name: "MacBattery",
            dependencies: ["SMCBridge", "MacBatteryCore"],
            path: "Sources/MacBattery"
        ),
        .testTarget(
            name: "MacBatteryCoreTests",
            dependencies: ["MacBatteryCore"],
            path: "Tests/MacBatteryCoreTests"
        )
    ]
)
