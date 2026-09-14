import Foundation
import AppKit
import Combine

/// 当前应用版本号。
///
/// 打包为 `.app` 时读取 Info.plist 的 `CFBundleShortVersionString`；
/// `swift run` 直接运行裸二进制（无 bundle 元数据）时回退到内置常量。
enum AppVersion {
    /// 未打包运行时的兜底版本号，发版时与 tag 保持一致。
    static let fallback = "1.1.0"

    static var current: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        return fallback
    }
}

/// 更新流程状态机（供 UI 展示）。
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(version: String, progress: Double)
    case downloaded(version: String, fileURL: URL)
    case failed(message: String)

    /// 一句话状态描述。
    var summary: String {
        switch self {
        case .idle:
            return "尚未检查"
        case .checking:
            return "正在检查更新…"
        case .upToDate:
            return "已是最新版本（\(AppVersion.current)）"
        case .available(let v):
            return "发现新版本 \(v)"
        case .downloading(let v, let p):
            return "正在下载 \(v)… \(Int(p * 100))%"
        case .downloaded(let v, _):
            return "\(v) 安装包已下载完成"
        case .failed(let m):
            return "更新失败：\(m)"
        }
    }

    /// 是否处于进行中（检查 / 下载），用于禁用按钮。
    var isBusy: Bool {
        switch self {
        case .checking, .downloading: return true
        default: return false
        }
    }
}

/// 语义化版本比较：仅比较数字段，`v` 前缀与非数字后缀（如 `-beta`）忽略。
enum VersionCompare {
    /// remote 是否比 local 更新。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote)
        let b = components(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ s: String) -> [Int] {
        let trimmed = (s.hasPrefix("v") || s.hasPrefix("V")) ? String(s.dropFirst()) : s
        return trimmed.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}

/// 在线自动更新：查询 GitHub Releases 最新版本，若比当前版本新则自动下载 DMG 到「下载」文件夹，
/// 并弹窗提示用户在访达中打开安装。
///
/// 数据源为 GitHub 公开 API，无需第三方依赖：
/// `https://api.github.com/repos/{owner}/{repo}/releases/latest`
@MainActor
final class UpdateChecker: NSObject, ObservableObject {

    /// GitHub 仓库（Releases 数据源）。
    private let repo = "zioon/MacBattery"

    /// 当前状态，驱动设置面板文案。
    @Published private(set) var state: UpdateState = .idle

    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    /// 正在下载的版本号（下载完成回调里回填）。
    private var pendingVersion = ""
    /// 是否正在查询（防止重复触发）。
    private var isChecking = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 检查更新。
    /// - Parameter interactive: 用户手动触发时为 `true`，会就「已最新 / 失败」弹窗；
    ///   启动时的自动检查为 `false`，仅在发现并下载到新版本时提示，避免打扰。
    func checkForUpdates(interactive: Bool) {
        guard downloadTask == nil, !isChecking else { return }
        isChecking = true
        state = .checking

        Task { @MainActor in
            defer { self.isChecking = false }
            do {
                let release = try await fetchLatestRelease()
                let remote = release.tagName

                guard VersionCompare.isNewer(remote, than: AppVersion.current) else {
                    state = .upToDate
                    if interactive { presentInfo("已是最新版本", "当前版本 \(AppVersion.current)。") }
                    return
                }

                state = .available(version: remote)

                guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                      let url = URL(string: asset.browserDownloadUrl) else {
                    state = .failed(message: "该版本未附带 DMG")
                    if interactive { presentError("未找到安装包", "最新版本 \(remote) 未附带 DMG 安装包。") }
                    return
                }

                startDownload(version: remote, url: url)
            } catch {
                state = .failed(message: error.localizedDescription)
                if interactive { presentError("检查更新失败", error.localizedDescription) }
            }
        }
    }

    // MARK: - 网络

    /// GitHub Release 的公开字段（下划线转驼峰由解码器统一处理）。
    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBattery", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let tip = http.statusCode == 404 ? "仓库或发布不存在" : "GitHub 返回 \(http.statusCode)"
            throw NSError(domain: "MacBattery.Update", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: tip])
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    private func startDownload(version: String, url: URL) {
        pendingVersion = version
        state = .downloading(version: version, progress: 0)
        let task = session.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    /// 下载完成后移动到「下载」文件夹并提示用户。
    private func finishDownload(_ temporaryFile: URL) {
        downloadTask = nil
        let name = "MacBattery-\(pendingVersion).dmg"
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = folder.appendingPathComponent(name)

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporaryFile, to: destination)
        } catch {
            state = .failed(message: error.localizedDescription)
            presentError("保存安装包失败", error.localizedDescription)
            return
        }

        state = .downloaded(version: pendingVersion, fileURL: destination)
        presentDownloaded(version: pendingVersion, file: destination)
    }

    // MARK: - 弹窗提示

    private func presentDownloaded(version: String, file: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = """
            安装包已自动下载到「下载」文件夹：
            \(file.lastPathComponent)

            打开 DMG 后把 MacBattery 拖入「应用程序」即可完成更新。
            """
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    private func presentInfo(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func presentError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateChecker: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading(let version, _) = self.state {
                self.state = .downloading(version: version, progress: progress)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 该临时文件在本方法返回后即被系统删除，必须先同步搬走。
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBattery-\(UUID().uuidString).dmg")
        try? FileManager.default.moveItem(at: location, to: staged)
        Task { @MainActor in self.finishDownload(staged) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        // 会话级回调对所有任务生效；这里只关心下载任务，避免把「检查更新」的失败误报成下载失败。
        guard let error, task is URLSessionDownloadTask else { return }
        Task { @MainActor in
            self.downloadTask = nil
            self.state = .failed(message: error.localizedDescription)
            self.presentError("下载更新失败", error.localizedDescription)
        }
    }
}
