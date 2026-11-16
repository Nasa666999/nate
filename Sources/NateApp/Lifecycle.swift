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
        mainWindow?.editor.finishComposition()
        let protectedDocuments = documents
        for document in protectedDocuments {
            document.buffer.isEditingSuspended = true
        }
        searchTask?.cancel()
        Task {
            // 尚未发布的打开请求不拥有写入副作用，退出时保留请求文件而不等待系统读取。
            instanceRequestTask?.cancel()
            if let task = searchTask {
                await task.value
            }
            var failures: [String] = []
            // 临时文档由最后一次统一恢复发布保护，避免逐标签重复写入整份工作区正文。
            for document in documents where document.url != nil {
                if !(await flush(document)) {
                    failures.append(document.name)
                }
            }
            let protected = await flushRecovery()
            if !failures.isEmpty || !protected {
                let alert = NSAlert()
                alert.messageText = protected ? "恢复副本已保存，部分原文件未保存" : "恢复内容尚未全部落盘"
                alert.informativeText = failures.joined(separator: "\n") + "\n取消可继续编辑并处理保存失败。"
                alert.addButton(withTitle: "取消退出")
                if protected {
                    alert.addButton(withTitle: "保留恢复副本并退出")
                }
                guard protected && alert.runModal() == .alertSecondButtonReturn else {
                    closing = false
                    for document in protectedDocuments where !document.closing {
                        document.buffer.isEditingSuspended = false
                    }
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
