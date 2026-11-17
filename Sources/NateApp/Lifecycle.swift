import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：Finder 冷启动和运行中打开事件进入同一工作区队列。
    /// 参数说明:
    /// - application: 系统应用对象。
    /// - urls: 用户明确要求打开的文件。
    /// 返回：初始化前排队，完成后逐个按文件身份去重。
    func application(_ application: NSApplication, open urls: [URL]) {
        if !initialized {
            pendingURLs.append(contentsOf: urls)
        }
        else {
            Task {
                for url in urls {
                    await openFile(url)
                }
            }
        }
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
        closing = true
        readIO.cancelReads()
        cancelCompletion()
        cancelStructure()
        externalCommandTask?.cancel()
        mainWindow?.editor.finishComposition()
        let protectedDocuments = documents
        // 先冻结所有现有正文，再等待外部动作，使最后确认的正文在等待期间保持不变。
        for document in protectedDocuments {
            document.setEditingSuspension(.applicationTermination, active: true)
        }
        searchTask?.cancel()
        // 不等待原文件和进程退出才开始保护正文，两个持久化通道必须保持独立推进。
        scheduleRecovery(force: true)
        Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            // 尚未发布的打开请求不拥有写入副作用，退出时保留请求文件而不等待系统读取。
            instanceRequestTask?.cancel()
            _ = await TaskBoundary.wait(
                until: deadline,
                while: {
                    externalCommandTask != nil || searchTask != nil || !closingDocumentIDs.isEmpty
                }
            )
            // 既有关闭仍可能移除或恢复标签，成员集合未收束时不能确认最终退出索引。
            guard closingDocumentIDs.isEmpty else {
                SystemIntegration.alert("关闭流程尚未完成，已取消退出", "正文保持保护；请等待当前关闭返回，再重新退出。文件写入任务仍可从工具菜单查看。")
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            var failures: [String] = []
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
            let exitBlocked = !unresolved.isEmpty || externalCommandTask != nil || !pendingBindings.isEmpty
            if exitBlocked {
                let bindings = pendingBindings.map {
                    $0.saveOperation?.target.path ?? $0.url?.path ?? $0.name
                }
                let paths = Array(Set(unresolved.map(\.target.path) + bindings)).sorted().joined(
                    separator: "\n"
                )
                SystemIntegration.alert(
                    "系统动作尚未确认，已取消退出",
                    paths + "\n已经进入的文件发布、目标关联或进程启动尚未确认。正文继续保留，可从工具菜单查看文件写入任务。"
                )
                restoreAfterCancelledExit(protectedDocuments)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if !failures.isEmpty || !protected {
                let alert = NSAlert()
                alert.messageText = protected ? "恢复副本已保存，部分原文件未保存" : "恢复内容尚未全部落盘"
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
