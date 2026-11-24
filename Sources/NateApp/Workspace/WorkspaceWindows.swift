import AppKit
import NateUI

extension ApplicationController {
    /// 业务作用：所有编辑窗口都指向同一工作区，文件身份、写入任务和撤销历史只在共享文档中维护。
    /// 参数说明: 无。
    /// 返回：已经登记的完整窗口集合，单窗口启动时使用已经建立的编辑窗口。
    var editorWindows: [EditorWindow] {
        if !workspaceWindows.isEmpty {
            return workspaceWindows
        }
        return mainWindow.map { [$0] } ?? []
    }

    /// 业务作用：异步文件请求只能发布到仍然登记的原窗口，允许无窗口时预载工作区。
    /// 参数说明:
    /// - window: 原请求捕获的实际窗口，为空表示预载时没有编辑窗口。
    /// 返回：窗口仍登记在共享工作区或确实处于无窗口状态时为真。
    func isWorkspaceWindowAvailable(_ window: EditorWindow?) -> Bool {
        guard let window else {
            return mainWindow == nil
        }
        return editorWindows.contains { $0 === window }
    }

    /// 业务作用：新建独立编辑窗口，同时把文档交给现有保存与恢复通道。
    /// 参数说明:
    /// - document: 窗口要展示的已有文档，省略时新建一个空白文档。
    /// 返回：窗口展示同一文档缓冲区并可独立编辑，退出、窗口或文档容量无效时无新窗口。
    @discardableResult
    func openWorkspaceWindow(document: WorkspaceDocument? = nil) -> EditorWindow? {
        guard !closing, editorWindows.count < 32, document != nil || documents.count < 1024,
            document.map({ candidate in
                !candidate.closing && documents.contains { $0 === candidate }
            }) ?? true,
            mainWindow?.finishCompositions() != false
        else {
            mainWindow?.status.stringValue = "当前窗口或文档状态不允许新建窗口。"
            return nil
        }
        let existing = editorWindows
        beginWorkspaceTabGroups()
        let target = document ?? newDocument(activateOnCreate: false)
        let window = EditorWindow(document: target.buffer)
        window.window?.setFrameAutosaveName("")
        if let original = mainWindow?.window {
            window.window?.setFrameTopLeftPoint(
                NSPoint(x: original.frame.minX + 24, y: original.frame.maxY - 24)
            )
        }
        applyDisplaySettings(currentDisplaySettings(), to: window)
        window.setEditorTheme(themePreferences.compiled)
        workspaceWindows = existing + [window]
        windowTabGroups[ObjectIdentifier(window)] = [target.buffer.id]
        connect(window)
        selectWorkspaceWindow(window)
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(window.editor)
        return window
    }

    /// 业务作用：将当前正文交给独立窗口，两个窗口共享文件身份和编辑历史。
    /// 参数说明: 无。
    /// 返回：存在活动正文时打开克隆，原窗口仍可访问同一正文。
    func openActiveDocumentWindow() {
        guard let active else {
            return
        }
        openWorkspaceWindow(document: active)
    }

    /// 业务作用：窗口取得输入焦点时同步菜单和命令路由，后台读写继续使用各自原文档。
    /// 参数说明:
    /// - window: 发出键盘焦点通知的已登记窗口。
    /// 返回：当前命令范围与该窗口实际文档一致，跨窗口旧选择任务失去发布资格。
    func selectWorkspaceWindow(_ window: EditorWindow) {
        let document = window.editor.document
        // 只有仍在工作区登记的原缓冲区能取得命令路由，已关闭或开始关闭的窗口不能重新获得输入目标。
        guard !closing, mainWindow !== window, editorWindows.contains(where: { $0 === window }),
            documents.contains(where: { $0.buffer === document && !$0.closing })
        else {
            return
        }
        // 撤销依赖旧焦点的异步意图，再发布新窗口和活动文档，防止迟到任务跨窗口改变选区。
        suspendSearchForInput()
        cancelQuickFind()
        cancelBookmarkAction()
        cancelSearchMarking()
        cancelDocumentMarkCopy()
        cancelTextTool()
        cancelStructure()
        cancelRunCommandPreparation()
        cancelMacro()
        mainWindow = window
        activeID = document.id
        refreshUI()
    }

    /// 业务作用：关闭一个编辑窗口时确认其中的组合输入，仍打开的共享文档继续沿原通道保存。
    /// 参数说明:
    /// - window: 用户请求关闭的原生窗口。
    /// 返回：其它编辑窗口仍在时只移除此窗口，最后一个窗口则进入应用的完整退出流程。
    func closeWorkspaceWindow(_ window: EditorWindow) {
        guard !closing, editorWindows.contains(where: { $0 === window }) else {
            return
        }
        let others = editorWindows.filter { $0 !== window }
        if others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        // 仍有未确认输入时保留对应窗口，不能借另一窗口仍显示同一缓冲区跳过其候选保护。
        guard window.finishCompositions() else {
            return
        }
        let wasCurrent = mainWindow === window
        if wasCurrent, let next = others.last {
            selectWorkspaceWindow(next)
            guard mainWindow === next else {
                return
            }
        }
        if let destination = mainWindow {
            retireWorkspaceTabGroup(window, preservingIn: destination, survivors: others)
        }
        workspaceWindows = others
        if directoryWorkspace?.window === window {
            // 窗口退出前撤销关联目录读取与观察权限，迟到结果不能重建已关闭的侧栏。
            directoryWorkspace?.stop()
            directoryWorkspace = nil
        }
        window.onWindowClose = nil
        window.onWorkspaceFocus = nil
        window.window?.close()
        if wasCurrent, let mainWindow {
            mainWindow.window?.makeKeyAndOrderFront(nil)
        }
        refreshUI()
        scheduleRecovery()
    }

    /// 业务作用：关闭文档或退出时逐个确认关联窗口的组合状态。
    /// 参数说明:
    /// - documentID: 明确要保护的文档，省略时检查全部打开窗口。
    /// 返回：全部关联候选已经确认或为空时允许继续，任一失败保留窗口与正文来源。
    func finishWorkspaceCompositions(documentID: UUID? = nil) -> Bool {
        editorWindows.allSatisfy { $0.finishCompositions(documentID: documentID) }
    }

    /// 业务作用：同一文档关闭后收回各窗口中它的所有编辑入口，剩余窗口显示仍登记的正文。
    /// 参数说明:
    /// - id: 已完成持久化并移出工作区的文档身份。
    /// - fallback: 保留在同一工作区的下一可用文档。
    /// 返回：旧编辑视图停止持有已关闭正文，后台窗口更新时保留各自焦点。
    func retireWorkspaceDocument(_ id: UUID, fallback: WorkspaceDocument) {
        for window in editorWindows {
            let key = ObjectIdentifier(window)
            windowTabGroups[key]?.removeAll { $0 == id }
            window.retireDocument(id)
            if window.editor.document.id == id {
                let replacement = workspaceTabDocuments(in: window).first ?? fallback
                attachWorkspaceTab(replacement.buffer.id, to: window)
                window.showDocument(replacement.buffer, focus: mainWindow === window)
                window.forgetTabViewPosition(id)
            }
        }
        if let mainWindow {
            activeID = mainWindow.editor.document.id
        }
    }

    /// 业务作用：后台窗口的提交仍按真实缓冲区标记待保存，不能误标当前窗口的另一正文。
    /// 参数说明:
    /// - window: 确认编辑的原窗口。
    /// 返回：已经提交的共享文档更新待保存状态，当前窗口内的变更继续走完整的编辑失效流程。
    func workspaceWindowDidEdit(_ window: EditorWindow) {
        guard editorWindows.contains(where: { $0 === window }),
            let document = documents.first(where: { $0.buffer === window.editor.document })
        else {
            return
        }
        if mainWindow === window && activeID == document.buffer.id {
            didEdit()
        }
        else {
            document.dirtyHint = true
            for editor in editorWindows {
                editor.refreshEditors()
            }
            refreshUI()
        }
    }

    /// 业务作用：编辑通知只标记待保存，不把每次输入排成全文 I/O。
    /// 参数说明: 无。
    /// 返回：标签立即反映修改，保存周期独立推进。
    func didEdit() {
        guard let active else {
            return
        }
        cancelBookmarkAction()
        cancelMultipleSelection()
        cancelQuickFind()
        cancelColumnInsertion()
        cancelHistoryAction()
        cancelLineSort()
        cancelTextTool()
        // 新正文撤销旧源行复制，等待读取不能再发布先前修订的剪贴板内容。
        cancelSearchResultExport()
        cancelSearchResultPathOpen()
        cancelDocumentMarkCopy()
        cancelSearchMarking()
        // 新正文已提交，原目录打开不再拥有旧修订与原光标的发布资格。
        directoryWorkspace?.cancelOpen()
        cancelCompletion()
        // 正文已经进入新修订，原增量快照和起点都不能继续发布。
        cancelIncrementalSearch(resetOrigin: true)
        if mainWindow?.isIncrementalSearchVisible == true {
            mainWindow?.incrementalSearch.feedback.stringValue = "正文已改变，可继续查找。"
        }
        active.dirtyHint = true
        for window in editorWindows {
            window.refreshEditors()
        }
        refreshUI()
        refreshVisibleIncrementalHighlights()
    }
}
