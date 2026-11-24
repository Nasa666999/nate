import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：Finder 冷启动和运行中打开事件进入同一工作区队列。
    /// 参数说明:
    /// - application: 系统应用对象。
    /// - urls: 用户明确要求打开的文件。
    /// 返回：初始化前按原事件分组排队，完成后按窗口设置打开并按文件身份去重。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !closing, !urls.isEmpty else {
            return
        }
        pendingFinderURLs.append(urls)
        startFinderOpenRequests()
    }

    /// 业务作用：最后窗口关闭也保留正常应用生命周期，由统一退出流程保护内容。
    /// 参数说明:
    /// - sender: 系统应用对象。
    /// 返回：窗口关闭不立即绕过保存退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 业务作用：退出前异步收束原文件与恢复通道，不在终止通知里才开始保存。
    /// 参数说明:
    /// - sender: 系统应用对象。
    /// 返回：terminateLater 保持事件循环，保存结果确定后再回复系统。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard initialized else {
            return .terminateNow
        }
        if closing {
            return .terminateCancel
        }
        // 确认失败的候选仍属于用户输入，不能先进入退出保护再丢弃未进入正文的内容。
        guard finishWorkspaceCompositions() else {
            return .terminateCancel
        }
        // 项目定义和正文分别保护，尚未确认的虚拟结构不能在正文保存后被静默丢弃。
        guard permitsProjectTermination() else {
            return .terminateCancel
        }
        closing = true
        themePreferences.watchGeneration = UUID()
        themePreferences.watchTask?.cancel()
        themePreferences.presentationTask?.cancel()
        themePreferences.form?.cancelEditing()
        cancelPausedWorkspaceImport()
        cancelMultipleSelection()
        cancelColumnInsertion()
        cancelHistoryAction()
        cancelLineSort()
        cancelTextTool()
        cancelDigest()
        cancelQuickFind()
        mainWindow?.refreshSelectedTextHighlights()
        cancelBookmarkAction()
        cancelSearchResultExport()
        cancelSearchResultPathOpen()
        cancelDocumentMarkCopy()
        // 退出即将固定恢复元数据，先撤销只读查询的光标发布权。
        cancelIncrementalSearch(resetOrigin: true)
        cancelProjectOpen()
        directoryWorkspace?.pause()
        if let findWindow {
            scheduleSearchSettings(findWindow.state)
        }
        readIO.cancelReads()
        cancelCompletion()
        cancelStructure()
        externalCommandTask?.cancel()
        cancelMacro()
        macroLibrary.importTask?.cancel()
        cancelKeyboardMapImport()
        cancelUserConfigurationOperation()
        cancelDocumentComparison()
        cancelRunCommandImport()
        cancelRunCommandPreparation()
        let protectedDocuments = documents
        // 先冻结所有现有正文，再等待外部动作，使最后确认的正文在等待期间保持不变。
        for document in protectedDocuments {
            document.setEditingSuspension(.applicationTermination, active: true)
        }
        searchTask?.cancel()
        resultNavigationTask?.cancel()
        // 不等待原文件和进程退出才开始保护正文，两个持久化通道必须保持独立推进。
        scheduleRecovery(force: true)
        scheduleSidebarRecovery(force: true)
        scheduleWorkspaceWindowLayout(force: true)
        Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            // 尚未发布的打开请求不拥有写入副作用，退出时保留请求文件而不等待系统读取。
            instanceRequestTask?.cancel()
            _ = await TaskBoundary.wait(
                until: deadline,
                while: {
                    externalCommandTask != nil || searchTask != nil || searchSettingsTask != nil
                        || historyPersistence.task != nil
                        || macroLibrary.task != nil
                        || keyboardMap.task != nil
                        || runCommands.task != nil
                        || !closingDocumentIDs.isEmpty
                }
            )
            // 历史归档可能仍在系统文件发布中，不能结束进程后把尚未确认的替换当作已经保存。
            guard historyPersistence.task == nil else {
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                mainWindow?.status.stringValue = "历史归档仍在确认，已取消退出；请等待后重试。"
                return
            }
            // 宏库可能仍在发布完整定义，未返回的替换不能在进程结束时被当成保存成功。
            guard macroLibrary.task == nil else {
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                mainWindow?.status.stringValue = "命名宏仍在确认，已取消退出；请等待后重试。"
                return
            }
            // 设置发布尚未返回时不能结束进程，否则用户无法区分已保存与仅在内存生效的组合。
            guard keyboardMap.task == nil else {
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                mainWindow?.status.stringValue = "快捷键映射仍在确认，已取消退出；请等待后重试。"
                return
            }
            // 配置发布可能已经替换原文件，实际任务未返回前不能把未确认状态当作已保存并结束进程。
            guard runCommands.task == nil else {
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                mainWindow?.status.stringValue = "运行配置仍在确认，已取消退出；请等待后重试。"
                return
            }
            // 既有关闭仍可能移除或恢复标签，成员集合未收束时不能确认最终退出索引。
            guard closingDocumentIDs.isEmpty else {
                SystemIntegration.alert("关闭流程尚未完成，已取消退出", "正文保持保护；请等待当前关闭返回，再重新退出。文件写入任务仍可从工具菜单查看。")
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            var failures: [String] = []
            if historyPersistence.enabled, let failure = historyPersistence.failure {
                failures.append(failure)
            }
            if !macroLibrary.writable, let failure = macroLibrary.failure {
                failures.append("命名宏：" + failure)
            }
            if !keyboardMap.writable, let failure = keyboardMap.failure {
                failures.append("快捷键：" + failure)
            }
            if !runCommands.writable, let failure = runCommands.failure {
                failures.append("运行配置：" + failure)
            }
            if !(await flushSidebarRecovery(until: deadline)) {
                failures.append(sidebarRecovery.failure ?? "侧栏恢复状态尚未确认保存。")
            }
            if !(await flushWorkspaceWindowLayout(until: deadline)) {
                failures.append(windowRecovery.failure ?? "窗口布局尚未确认保存。")
            }
            if searchSettingsTask != nil || searchSettingsError != nil {
                failures.append(searchSettingsError ?? "搜索设置仍在保存。")
            }
            // 临时文档由最后一次统一恢复发布保护，避免逐标签重复写入整份工作区正文。
            for document in documents where document.url != nil {
                if !(await flush(document, deadline: deadline)) {
                    failures.append(document.name)
                }
            }
            // 原路径用尽等待预算后，恢复目录仍取得独立等待机会，不让失联磁盘剥夺保护副本。
            let protected = await flushRecovery()
            fileOperations.suspendPublications()
            let unresolved = fileOperations.snapshots.filter {
                $0.hasActivePublication
            }
            let pendingBindings = documents.filter {
                $0.bindingChange
            }
            // 目标关联尚未确认时不能按旧路径退出恢复，否则未决另存结果可能被误当成仍可写回旧路径。
            // 侧栏实际写入同样必须真实收束，不能在放弃草稿后仍让旧归档发布于进程退出边界。
            let exitBlocked =
                !unresolved.isEmpty || externalCommandTask != nil || !pendingBindings.isEmpty
                || sidebarRecovery.task != nil || windowRecovery.task != nil
            if exitBlocked {
                let bindings = pendingBindings.map {
                    $0.saveOperation?.target.path ?? $0.url?.path ?? $0.name
                }
                let paths = Array(Set(unresolved.map(\.target.path) + bindings)).sorted().joined(
                    separator: "\n"
                )
                SystemIntegration.alert(
                    "系统动作尚未确认，已取消退出",
                    paths + "\n文件发布、恢复布局、目标关联或进程启动尚未确认。正文继续保留，可从工具菜单查看文件写入任务。"
                )
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if !failures.isEmpty || !protected {
                let alert = NSAlert()
                alert.messageText = protected ? "恢复副本已保存，部分内容尚未持久化" : "恢复内容尚未全部落盘"
                alert.informativeText = failures.joined(separator: "\n") + "\n取消可继续编辑并处理保存失败。"
                alert.addButton(withTitle: "取消退出")
                if protected {
                    alert.addButton(withTitle: "保留恢复副本并退出")
                }
                let choice = alert.runModal()
                guard protected && choice == .alertSecondButtonReturn else {
                    restoreAfterCancelledExit(protectedDocuments)
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            autosaveTask?.cancel()
            DistributedNotificationCenter.default().removeObserver(self)
            externalObservationTask?.cancel()
            instanceRequestTask?.cancel()
            searchTask?.cancel()
            resultNavigationTask?.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 业务作用：取消退出后只解除退出暂停并恢复新动作入口，不恢复旧发布权限。
    /// 参数说明:
    /// - protectedDocuments: 开始退出时暂停编辑的文档集合。
    /// 返回：原有保存周期继续推进，仍未返回的任务保持登记。
    func restoreAfterCancelledExit(_ protectedDocuments: [WorkspaceDocument]) {
        closing = false
        startFinderOpenRequests()
        scheduleSidebarRecovery(force: true)
        directoryWorkspace?.resume()
        fileOperations.resumePublications()
        for document in protectedDocuments + documents {
            document.setEditingSuspension(.applicationTermination, active: false)
        }
        if documents.isEmpty {
            _ = newDocument()
        }
        else if let selected = active ?? documents.first {
            activate(selected.buffer.id)
        }
    }

    /// 业务作用：重新激活时重验外部文件，保存事件不能通过时间窗口忽略冲突。
    /// 参数说明:
    /// - notification: 激活通知。
    /// 返回：异步检查所有已打开原路径。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard initialized else {
            return
        }
        Task {
            await inspectExternalChanges()
        }
    }
}
