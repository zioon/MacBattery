import Foundation
import Combine
import MacBatteryCore

/// 界面语言的运行时状态。
///
/// 职责单一：把「设置里选的语言」（由 `SettingsStore` 持久化）与「引擎实际加载的语言」
/// （`L10n`）打通，并作为 SwiftUI 可观察源驱动界面重绘。
///
/// 刻意**不加 `@MainActor`**：视图 `body` 与 `NSHostingView` 的构造都在主线程，
/// 但加注隔离会让 `LocalizationManager.shared` 在非隔离上下文的读取变成编译错误，
/// 而本项目所有涉及文案的调用点都在主线程 —— 与既有 `SettingsStore` 的约定一致。
final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    /// 用户在设置里选的语言（可能是 `.system`）。
    @Published private(set) var language: AppLanguage = AppLanguage.fallback

    private init() {}

    /// 应用语言设置：更新引擎并通知观察者。
    ///
    /// 幂等且廉价：`SettingsStore.commit()` 会被 TDP 滑块拖动高频触发，语言未变时
    /// 既不重读资源也不发布变更，避免无谓的整树重绘。
    func apply(_ language: AppLanguage) {
        L10n.shared.setLanguage(language)
        if self.language != language {
            self.language = language
        }
    }

    /// 引擎实际加载的语言（`.system` 已解析成具体语言）。
    var resolvedLanguage: AppLanguage { L10n.shared.language }
}
