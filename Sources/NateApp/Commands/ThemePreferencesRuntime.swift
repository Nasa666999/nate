import AppKit
import NateCore
import NateStorage
import NateSyntax
import NateUI

@MainActor
final class ThemePreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var sourceValid = true
    var sourceDomain: UserDefaults?
    var source: NSDictionary?
    var generation = UUID()
    var library: EditorThemeLibrary?
    var compiled: EditorThemeSnapshot?
    var bundled: [EditorThemeEntry] = []
    var styleNames: [String: [String: String]] = [:]
    var bundledWarning: String?
    var warning: String?
    let io = IOExecutor(name: "nate.themes", concurrency: 1, maximumStalled: 2)
    var presentationTask: Task<Void, Never>?
    var form: ThemePreferencesWindow?
    var watchTask: Task<Void, Never>?
    var watchGeneration = UUID()
    var observed: [UUID: ThemeSourceStamp] = [:]
    var watchedPaths: [UUID: String] = [:]
    var verifiedAt: [UUID: ContinuousClock.Instant] = [:]
    var sourceEvidence: [UUID: DiskBaseline] = [:]
    var sourceWarnings: [UUID: String] = [:]
    var pendingDraft: EditorThemeLibrary?

    /// 业务作用：主题偏好、窗口草稿和外部监视分别持有资格，尚未读取时不保存默认主题。
    /// 参数说明: 无。
    /// 返回：没有偏好发布或外部读取权限的独立主题运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：主题只捕获自己的完整偏好键，用户配置包、UDL 和显示字体分别持有来源。
    /// 参数说明:
    /// - domain: 当前明确连接的偏好域。
    /// 返回：保留未设置与原类型差异的只读来源证据。
    func themePreferenceSource(_ domain: UserDefaults) -> NSDictionary {
        ["editorThemeLibrary": domain.object(forKey: "editorThemeLibrary") ?? NSNull()] as NSDictionary
    }

    /// 业务作用：主题库在后台完成完整解码与选中项快照，损坏归档保留原值并采用系统呈现。
    /// 参数说明: 无。
    /// 返回：来源仍有效时发布完整已知主题库，读取本身不保存默认值。
    func loadThemeLibrary() async {
        let runtime = themePreferences
        let domain = runtime.defaults ?? .standard
        let source = themePreferenceSource(domain)
        if runtime.loaded, runtime.sourceDomain === domain, runtime.source?.isEqual(source) == true {
            return
        }
        runtime.watchGeneration = UUID()
        runtime.watchTask?.cancel()
        runtime.watchTask = nil
        runtime.generation = UUID()
        let generation = runtime.generation
        var candidate: EditorThemeLibrary?
        var compiled: EditorThemeSnapshot?
        var warning = runtime.bundledWarning
        var valid = true
        do {
            if let object = domain.object(forKey: "editorThemeLibrary") {
                guard let data = object as? Data, data.count <= 16 * 1024 * 1024 else {
                    throw NateError.message("主题库不是 16 MiB 以内的完整归档。")
                }
                let prepared = try await runtime.io.readCancellable {
                    token in
                    let library = try EditorThemeLibrary.decode(
                        data,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let selected = library.entries.first(where: {
                        $0.id == library.selectedID
                    })
                    let snapshot = try selected.map {
                        try EditorThemeSnapshot(
                            $0.definition,
                            permit: {
                                !token.isCancelled
                            }
                        )
                    }
                    return (library, snapshot)
                }
                candidate = prepared.0
                compiled = prepared.1
            }
            else {
                candidate = try EditorThemeLibrary(entries: runtime.bundled)
            }
        }
        catch {
            valid = false
            warning = "主题库未读取，原归档保留，本次采用系统与原资源样式。" + error.localizedDescription
            candidate = try? EditorThemeLibrary(entries: runtime.bundled)
        }
        // 后台解码不能覆盖后来连接的偏好域或用户已经应用的新库，失去原来源时保持当前显示。
        guard !closing, !Task.isCancelled, runtime.generation == generation,
            (runtime.defaults ?? .standard) === domain,
            source.isEqual(themePreferenceSource(domain))
        else {
            return
        }
        runtime.loaded = true
        runtime.sourceDomain = domain
        runtime.source = source
        runtime.sourceValid = valid
        runtime.library = candidate
        runtime.compiled = compiled
        runtime.warning = warning
        mainWindow?.setEditorTheme(compiled)
        restartThemeWatching()
    }
}
