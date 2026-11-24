import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class WorkspaceWindowRecovery {
    let io = IOExecutor(name: "nate.window.layout", concurrency: 1, maximumStalled: 0)
    var loaded = false
    var writable = false
    var baseline: DiskBaseline?
    var saved: WindowSessionLayout?
    var task: Task<Void, Never>?
    var failure: String?
    var nextRetry = ContinuousClock.Instant.now

    /// 业务作用：窗口布局独立保有实际磁盘来源和当前任务，不以正文保存成功替代自己的确认。
    /// 参数说明: 无。
    /// 返回：尚未读取原布局且未取得覆盖资格的状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：启动时先获取原窗口布局及真实基线，布局异常时允许正文独立恢复。
    /// 参数说明: 无。
    /// 返回：同一恢复目录的窗口布局或空；读取失败保留原文件并停用当前自动覆盖。
    func loadWorkspaceWindowLayout() async -> WindowSessionLayout? {
        guard recoveryReady, let store = recovery else {
            return nil
        }
        let runtime = windowRecovery
        do {
            let loaded = try await runtime.io.readCancellable {
                token in
                try store.restoreWindowLayout(permit: { !token.isCancelled })
            }
            guard !closing, recovery?.directory == store.directory else {
                return nil
            }
            runtime.baseline = loaded?.baseline
            runtime.saved = loaded?.layout
            runtime.loaded = true
            runtime.writable = true
            runtime.failure = nil
            return loaded?.layout
        }
        catch {
            runtime.loaded = true
            runtime.writable = false
            runtime.failure = "窗口布局未能读取，原布局保留：" + error.localizedDescription
            return nil
        }
    }

    /// 业务作用：布局引用与同一工作区的文档身份集合一致时才重建独立窗口及分屏。
    /// 参数说明:
    /// - layout: 已完整验证的持久化布局，首次使用或读取失败时为空。
    /// - fallback: 原工作区索引中的合法活动文档。
    /// 返回：能够接收启动命令的窗口；原标签集合改变时按恢复文档索引建立单窗口。
    func makeRestoredWorkspaceWindows(
        from layout: WindowSessionLayout?,
        fallback: WorkspaceDocument
    ) -> EditorWindow {
        let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.buffer.id, $0) })
        if let layout, (try? layout.validate()) != nil,
            layout.documentIDs == Set(existing.keys)
        {
            let restored = layout.windows.compactMap {
                session -> EditorWindow? in
                guard let document = existing[session.primary.documentID] else {
                    return nil
                }
                let window = EditorWindow(document: document.buffer)
                window.window?.setFrameAutosaveName("")
                loadEditorPreferences(into: window)
                let secondary = session.secondary.flatMap { existing[$0.documentID]?.buffer }
                window.restoreWindowSession(session, secondaryDocument: secondary)
                return window
            }
            if restored.count == layout.windows.count {
                // 全部窗口和正文引用已就绪，统一发布完整工作区，避免首个焦点事件只看到部分分组。
                workspaceWindows = restored
                windowTabGroups = Dictionary(
                    uniqueKeysWithValues: zip(restored, layout.windows).map {
                        (ObjectIdentifier($0.0), $0.1.tabs)
                    }
                )
                let activeWindow = restored[layout.activeWindow]
                mainWindow = activeWindow
                activeID = activeWindow.editor.document.id
                for window in restored {
                    connect(window)
                }
                return activeWindow
            }
        }
        let window = EditorWindow(document: fallback.buffer)
        loadEditorPreferences(into: window)
        mainWindow = window
        connect(window)
        return window
    }

    /// 业务作用：将所有可恢复窗口的真实成员和视图状态一次固定，过渡中的半份分组不进入磁盘。
    /// 参数说明: 无。
    /// 返回：覆盖当前全部正文和活动窗口的完整布局，无原生窗口或成员正在切换时为空。
    func captureWorkspaceWindowLayout() -> WindowSessionLayout? {
        let windows = editorWindows
        guard let selected = windows.firstIndex(where: { $0 === mainWindow }) else {
            return nil
        }
        let sessions = windows.compactMap { $0.windowSession(tabs: workspaceTabIDs(in: $0)) }
        guard sessions.count == windows.count else {
            return nil
        }
        let layout = WindowSessionLayout(windows: sessions, activeWindow: selected)
        return layout.documentIDs == Set(documents.map(\.buffer.id)) ? layout : nil
    }

    /// 业务作用：定期同步变更的窗口视图，正文索引和原文件保存仍可独立推进。
    /// 参数说明:
    /// - force: 退出时是否跳过暂时的失败退避，以本次真实布局完成最终确认。
    /// 返回：有合法最新快照和写入资格时启动单一布局任务；无变化时不重写。
    func scheduleWorkspaceWindowLayout(force: Bool = false) {
        let runtime = windowRecovery
        guard runtime.writable, runtime.task == nil, let store = recovery, recoveryStorage.failure == nil,
            force || ContinuousClock.now >= runtime.nextRetry,
            let layout = captureWorkspaceWindowLayout(), layout != runtime.saved
        else {
            return
        }
        let expected = runtime.baseline
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
            }
            do {
                let baseline = try await runtime.io.runCancellable {
                    token in
                    try store.publishWindowLayout(layout, expected: expected, permit: { !token.isCancelled })
                }
                guard self?.recovery?.directory == store.directory else {
                    return
                }
                // 只有实际写入确认后才推进基线，等待期间的新布局留给下一周期。
                runtime.baseline = baseline
                runtime.saved = layout
                runtime.failure = nil
                runtime.nextRetry = .now
            }
            catch is RecoveryStorageBusy {
                runtime.nextRetry = .now.advanced(by: .seconds(1))
            }
            catch {
                runtime.failure = "窗口布局尚未保存，原文档独立保护：" + error.localizedDescription
                runtime.nextRetry = .now.advanced(by: .seconds(5))
            }
            self?.refreshUI()
        }
    }

    /// 业务作用：退出前等待已开始的布局发布，再确认期间产生的最终状态。
    /// 参数说明:
    /// - deadline: 退出为布局通道保留的等待期限。
    /// 返回：最终布局已确认或当前没有布局恢复来源时为真；失败时保持原布局并提示。
    func flushWorkspaceWindowLayout(until deadline: ContinuousClock.Instant) async -> Bool {
        guard windowRecovery.loaded else {
            return true
        }
        guard await TaskBoundary.wait(until: deadline, while: { windowRecovery.task != nil }) else {
            return false
        }
        scheduleWorkspaceWindowLayout(force: true)
        guard await TaskBoundary.wait(until: deadline, while: { windowRecovery.task != nil }) else {
            return false
        }
        return windowRecovery.failure == nil && windowRecovery.saved == captureWorkspaceWindowLayout()
    }
}
