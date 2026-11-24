import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：通知只唤醒已取得工作区租约的实例，请求正文从私有目录读取。
    /// 参数说明:
    /// - notification: 不携带可信启动参数的本地唤醒事件。
    /// 返回：主实例异步处理已完整发布的请求。
    @objc func receiveInstanceRequest(_ notification: Notification) {
        guard initialized, instanceLease != nil else {
            return
        }
        scheduleInstanceRequests()
    }

    /// 业务作用：打开文件的等待不占用每秒保存调度，且同时只有一个请求消费任务。
    /// 参数说明: 无。
    /// 返回：登记可在退出时收束的处理任务。
    func scheduleInstanceRequests() {
        guard instanceRequestTask == nil, !closing else {
            return
        }
        instanceRequestTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                self.instanceRequestTask = nil
            }
            await self.drainInstanceRequests()
        }
    }

    /// 业务作用：串行消费跨进程打开请求，文件身份仍进入同一工作区去重与写入协调。
    /// 参数说明: 无。
    /// 返回：完成请求才移除发布文件；启动中排队和通知合并不会丢失路径。
    func drainInstanceRequests() async {
        guard initialized, instanceLease != nil, !closing, !processingInstanceRequests,
            let inbox = instanceInbox
        else {
            return
        }
        processingInstanceRequests = true
        defer {
            processingInstanceRequests = false
        }
        do {
            let requests = try await fileIO.run {
                try inbox.requests()
            }
            for request in requests {
                guard !closing else {
                    return
                }
                do {
                    let arguments = try JSONDecoder().decode(CLIArguments.self, from: request.data)
                    let window = await handleCLI(arguments)
                    // 关闭期间读取可以晚到，但请求不能被当作已经打开并从队列删除。
                    guard !closing, !Task.isCancelled else {
                        return
                    }
                    if isWorkspaceWindowAvailable(window) {
                        window?.window?.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
                catch {
                    SystemIntegration.alert("启动请求无效", error.localizedDescription)
                }
                try await fileIO.run {
                    try inbox.complete(request.id)
                }
            }
        }
        catch {
            mainWindow?.status.stringValue = "启动请求仍保留：" + error.localizedDescription
        }
    }
}
