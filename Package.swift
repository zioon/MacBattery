// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MacBattery",
    // 声明默认语言（开发语言）：SwiftPM 在 target 含本地化资源（*.lproj）时**强制要求**该字段，
    // 否则 manifest 解析阶段就报 "manifest property 'defaultLocalization' not set"。
    // 取 zh-Hans 与 `AppLanguage.fallback` 一致：既有界面文案都是中文，译文缺失时回退到它。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // 纯逻辑层（U-09）：无 AppKit / IOKit 依赖，可独立单测。
        // 约定：本目录内禁止 import AppKit / IOKit —— 破坏这条约定就会让测试失去意义。
        // 多语言引擎（Localization/）与语言资源（Resources/*.lproj）刻意放在本层：
        // 本机没有 Swift 工具链，CI 的 `swift test` 是唯一编译通道，把回退链与
        // 「各语言键名一致性」做成可单测的纯逻辑，才能在合并前就验证，而不是靠肉眼看界面。
        .target(
            name: "MacBatteryCore",
            path: "Sources/MacBatteryCore",
            resources: [
                .process("Resources")
            ]
        ),
        // C 目标：AppleSMC 读取（复用经验证的 C 实现，保证 80 字节协议帧布局）。
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge"
        ),
        // root helper 守护：既读 SMC 整机功率，也是充电上限的**唯一执行者**（写充电抑制键）。
        // 依赖 MacBatteryCore 是为了共用 App ↔ helper 的指令/回执协议定义
        //（ChargeLimitWire）—— 协议字段一旦两边各写一份，就会出现"编译能过、运行时静默失效"
        // 的错位缺陷，而症状只是"开关点了没反应"，极难排查。
        .executableTarget(
            name: "MacBatteryHelper",
            dependencies: ["SMCBridge", "MacBatteryCore"],
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
