import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：登记唯一保留工作区导入，清单、选择和正文读取共用可撤销身份。
    /// 参数说明: 无。
    /// 返回：先登记再异步读取，重复启动和退出期间均不创建另一个导入任务。
    func showPausedWorkspaces() {
        guard !closing, let support = applicationSupport, let window = mainWindow,
            pausedWorkspace.task == nil
        else {
            return
        }
        let runtime = pausedWorkspace
        runtime.generation = UUID()
        let request = runtime.generation
        runtime.published = false
        runtime.failure = nil
        runtime.task = Task {
            defer {
                if runtime.generation == request {
                    runtime.task = nil
                    self.refreshUI()
                }
            }
            do {
                let choices = try await runtime.io.readCancellable {
                    token in
                    try PausedWorkspaceReading.choices(
                        in: support,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                guard self.pausedImportIsCurrent(request, in: window) else {
                    return
                }
                guard !choices.isEmpty else {
                    SystemIntegration.alert("保留工作区", "没有因跳过恢复而保留的先前工作区。")
                    return
                }
                guard let chosen = self.choosePausedWorkspace(choices) else {
                    return
                }
                let origin = PausedWorkspaceOrigin(application: self, window: window)
                let metadata = try await runtime.io.readCancellable {
                    token -> (state: SidebarRecoveryState?, warning: String?) in
                    do {
                        let store = try PausedWorkspaceReading.store(at: chosen)
                        let result = try store.restoreSidebars(permit: {
                            !token.isCancelled
                        })
                        _ = try PausedWorkspaceReading.store(at: chosen)
                        return (result.state, result.warning)
                    }
                    catch is CancellationError {
                        throw CancellationError()
                    }
                    catch {
                        return (nil, "侧栏不可用：" + error.localizedDescription)
                    }
                }
                guard self.pausedImportIsCurrent(request, in: window), origin.matches(self),
                    let selection = self.choosePausedContents(metadata.state, warning: metadata.warning)
                else {
                    return
                }
                let publicationOrigin = PausedWorkspaceOrigin(application: self, window: window)
                try await self.importPausedWorkspace(
                    chosen,
                    includeDocuments: selection.documents,
                    sidebars: selection.sidebars,
                    authority: selection.authority,
                    origin: publicationOrigin,
                    request: request,
                    in: window
                )
            }
            catch is CancellationError {
                // 撤销先收回发布资格，晚到的只读返回不能弹窗或导入任何内容。
            }
            catch {
                guard self.pausedImportIsCurrent(request, in: window) else {
                    return
                }
                runtime.failure = "保留工作区未导入：" + error.localizedDescription
                self.refreshUI()
            }
        }
        refreshUI()
    }

    /// 业务作用：撤销尚未发布的导入，已加入内存的完整工作区继续由正常恢复保护负责。
    /// 参数说明: 无。
    /// 返回：旧读取失去界面发布资格；真实系统读取仍留在独立通道中直到返回。
    func cancelPausedWorkspaceImport() {
        let runtime = pausedWorkspace
        guard runtime.task != nil, !runtime.published else {
            return
        }
        // 先撤销身份，再请求停止读取，避免取消与真实返回交错时取得旧发布权。
        runtime.generation = UUID()
        runtime.task?.cancel()
        runtime.task = nil
        runtime.io.cancelReads()
        runtime.failure = nil
        refreshUI()
    }

    /// 业务作用：所有异步边界共用原窗口与任务身份，取消和退出立即停止旧导入的界面副作用。
    /// 参数说明:
    /// - request: 本次任务的唯一身份。
    /// - window: 发起任务的真实窗口。
    /// 返回：任务、窗口和工作区均仍有效时为真。
    func pausedImportIsCurrent(_ request: UUID, in window: EditorWindow) -> Bool {
        !closing && !Task.isCancelled && pausedWorkspace.generation == request
            && mainWindow === window
    }

    /// 业务作用：按最终选择完整读取并发布保留内容，当前工作区的恢复归档仍使用自己的写入权限。
    /// 参数说明:
    /// - directory: 用户明确选择的保留目录。
    /// - includeDocuments: 是否导入独立正文副本。
    /// - sidebars: 明确选择替换的项目和目录侧栏。
    /// - authority: 用户确认时的当前侧栏证据。
    /// - origin: 用户确认时的正文导航证据。
    /// - request: 当前导入身份。
    /// - window: 原工作区窗口。
    /// 返回：完整发布后请求正文和侧栏落盘；失败保留原保留目录，未确认落盘明确留在状态栏。
    func importPausedWorkspace(
        _ directory: URL,
        includeDocuments: Bool,
        sidebars: SidebarRecoveryState?,
        authority: PausedSidebarAuthority?,
        origin: PausedWorkspaceOrigin,
        request: UUID,
        in window: EditorWindow
    ) async throws {
        guard pausedImportIsCurrent(request, in: window) else {
            throw CancellationError()
        }
        var remaining = RecoveryLimits.workspaceBytes
        if includeDocuments {
            for document in documents {
                guard document.buffer.text.byteCount <= remaining else {
                    throw NateError.message("当前正文已超过恢复容量，请先关闭部分文档。")
                }
                remaining -= document.buffer.text.byteCount
            }
        }
        let bytes = remaining, count = max(0, RecoveryLimits.documents - documents.count)
        let runtime = pausedWorkspace
        let payload = try await runtime.io.readCancellable {
            token in
            try PausedWorkspaceReading.read(
                directory,
                includeDocuments: includeDocuments,
                sidebars: sidebars,
                remainingBytes: bytes,
                remainingDocuments: count,
                permit: {
                    !token.isCancelled
                }
            )
        }
        guard pausedImportIsCurrent(request, in: window) else {
            throw CancellationError()
        }
        let currentOrigin = origin.matches(self)
        let navigate = currentOrigin && origin.isEditorOrigin
        if sidebars != nil && !currentOrigin {
            throw NateError.message("导入等待期间导航或输入已改变，未替换侧栏。")
        }
        _ = try publishPausedWorkspace(payload, in: window, authority: authority, activateImported: navigate)
        // 内存整批发布之后不能再报告成尚未导入，后续取消或退出遵循正常工作区持久化语义。
        runtime.published = true
        scheduleSidebarRecovery(force: true)
        var bodySaved = true
        if includeDocuments {
            bodySaved = await flushRecovery()
        }
        var sidebarSaved = true
        if sidebars != nil {
            sidebarSaved = await flushSidebarRecovery(until: .now.advanced(by: .seconds(30)))
        }
        if !bodySaved || !sidebarSaved {
            runtime.failure = "保留工作区已导入；当前恢复副本尚未全部确认保存，原保留记录继续保留。"
        }
        else {
            runtime.failure = nil
        }
        refreshUI()
    }
}
