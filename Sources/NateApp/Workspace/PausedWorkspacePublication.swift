import AppKit
import NateCore
import NateStorage
import NateUI

struct PausedSidebarAuthority {
    let projects: [UUID]
    let directory: UUID?
    let navigation: UUID
    let state: SidebarRecoveryState
}

extension ApplicationController {
    /// 业务作用：替换侧栏的确认绑定完整原定义与目录根，界面或定义往返后不能沿旧确认覆盖新状态。
    /// 参数说明: 无。
    /// 返回：当前三个面板均无在途定义动作时提供完整证据；缺少窗口或忙碌时为空。
    func pausedSidebarAuthority() -> PausedSidebarAuthority? {
        guard
            projectPanelStates.allSatisfy({
                $0.operation == nil
            }), let state = captureSidebarState()
        else {
            return nil
        }
        return PausedSidebarAuthority(
            projects: projectPanelStates.map(\.generation),
            directory: directoryWorkspace?.sidebarGeneration,
            navigation: projectOpenGeneration,
            state: state
        )
    }

    /// 业务作用：完整导入内容先准备后一次发布，正文使用新身份，侧栏替换只使用仍有效的原确认。
    /// 参数说明:
    /// - payload: 已完整校验的正文与所选侧栏。
    /// - window: 用户发起导入时的实际工作区窗口。
    /// - authority: 选择恢复侧栏时捕获的原定义证据，正文单独导入时可为空。
    /// - activateImported: 原导航意图仍有效时显示源活动文档，否则只在后台加入。
    /// 返回：新文档身份列表；任何容量、侧栏证据或输入保护失败均不发布部分内容，不授予原文件写入权。
    func publishPausedWorkspace(
        _ payload: PausedWorkspacePayload,
        in window: EditorWindow,
        authority: PausedSidebarAuthority?,
        activateImported: Bool
    ) throws -> [UUID] {
        guard !closing, mainWindow === window else {
            throw CancellationError()
        }
        if let sidebars = payload.sidebars {
            try sidebars.validate()
            // 侧栏替换不能借缺席或往返后的同名节点取得权限，候选输入也不因恢复布局被迫确认。
            guard let authority, projectPanelStates.map(\.generation) == authority.projects,
                directoryWorkspace?.sidebarGeneration == authority.directory,
                projectOpenGeneration == authority.navigation,
                captureSidebarState() == authority.state,
                projectPanelStates.allSatisfy({
                    $0.operation == nil
                }),
                !window.hasMarkedEditorInput, !window.incrementalSearch.isEditingInput,
                findWindow?.isEditingInput != true
            else {
                throw NateError.message("当前侧栏或输入已改变，未应用旧导入确认。")
            }
        }
        guard payload.documents.count <= 1024 - min(1024, documents.count) else {
            throw NateError.message("导入后超过 1024 个文档，原保留内容仍在，未导入部分正文。")
        }
        var remaining = 2 * 1024 * 1024 * 1024
        if !payload.documents.isEmpty {
            for count in documents.map({
                $0.buffer.text.byteCount
            })
                + payload.documents.map({
                    $0.text.byteCount
                })
            {
                guard count <= remaining else {
                    throw NateError.message("导入后正文超过 2 GiB 恢复预算，原保留内容仍在，未导入部分正文。")
                }
                remaining -= count
            }
        }
        var additions: [WorkspaceDocument] = []
        var selected: UUID?
        for recovered in payload.documents {
            let record = recovered.metadata, tree = recovered.text
            let document = WorkspaceDocument(
                name: record.name + "（保留工作区）",
                text: record.text,
                textTree: tree,
                encoding: record.encoding,
                lineEnding: record.lineEnding ?? .lf
            )
            document.language = record.language
            document.pinned = record.pinned ?? false
            document.languageExplicit = true
            document.buffer.bookmarks = record.bookmarks
            try document.restoreSelections(from: record)
            document.buffer.isReadOnly = record.readOnly
            document.state = "保留工作区的独立恢复副本"
            if record.id == payload.active {
                selected = document.buffer.id
            }
            additions.append(document)
        }
        // 全部可失败的准备已完成，先恢复纯侧栏再加入整批正文，期间不跨越等待或模态确认。
        if let sidebars = payload.sidebars {
            try applySidebarState(sidebars, in: window)
        }
        documents.append(contentsOf: additions)
        if activateImported, let id = selected ?? additions.first?.buffer.id {
            activate(id)
            window.window?.makeFirstResponder(window.editor)
        }
        else {
            refreshUI()
        }
        if window.window?.isVisible != true {
            window.showWindow(nil)
        }
        return additions.map {
            $0.buffer.id
        }
    }
}
