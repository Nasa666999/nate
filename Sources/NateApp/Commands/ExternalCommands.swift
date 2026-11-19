import AppKit
import Foundation
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：一次运行进入完整临时输入，与命名配置共用变量准备、实际预览和明确执行门禁。
    /// 参数说明: 无。
    /// 返回：建立新的未保存表单，不在打开入口时执行程序。
    func configureRun() {
        showRunCommands(newDraft: true)
    }

    /// 业务作用：外部命令使用独立阻塞队列，取消权限传至进程组，避免占用原文件保存线程。
    /// 参数说明:
    /// - executable: 用户已确认的绝对程序路径。
    /// - arguments: 完成变量替换的固定参数。
    /// - directory: 固定工作目录。
    /// 返回：仅在任务仍有效且应用未退出时呈现完整输出。
    func executeExternalCommand(_ executable: String, arguments: [String], directory: URL?) {
        guard externalCommandTask == nil, !closing else {
            return
        }
        let executor = commandIO
        let query = queryGeneration
        let presentation = mainWindow?.resultGeneration
        externalCommandTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                self.externalCommandTask = nil
                self.refreshRunCommandPresentation()
            }
            do {
                let result = try await executor.runCancellable {
                    token in
                    try ProcessExecution.run(
                        executable: executable,
                        arguments: arguments,
                        directory: directory,
                        isCancelled: {
                            token.isCancelled
                        }
                    )
                }
                try Task.checkCancellation()
                guard !self.closing else {
                    return
                }
                self.presentExternalOutput(
                    "\(executable)\n退出状态 \(result.status)\n" + result.output,
                    query: query,
                    presentation: presentation
                )
            }
            catch is CancellationError {
                if !self.closing {
                    self.presentExternalOutput(
                        "外部命令已取消，已请求终止本次进程组。",
                        query: query,
                        presentation: presentation
                    )
                }
            }
            catch {
                if !self.closing {
                    self.presentExternalOutput(
                        "外部命令未完成：" + error.localizedDescription,
                        query: query,
                        presentation: presentation
                    )
                }
            }
        }
    }

    /// 业务作用：保留最后一次完整命令反馈，但不让迟到输出覆盖用户后来打开的搜索或工具结果。
    /// 参数说明:
    /// - text: 完整输出或明确的取消失败状态。
    /// - query: 命令启动时的搜索请求代次。
    /// - presentation: 命令启动时的结果面板代次。
    /// 返回：结果可从工具菜单主动查看；仅在展示权仍有效时立即显示。
    func presentExternalOutput(_ text: String, query: UUID, presentation: UUID?) {
        lastExternalOutput = text
        // 新查询即使尚未产生结果，也已经拥有后续展示权，旧命令只能保留独立结果。
        guard !closing, query == queryGeneration, presentation == mainWindow?.resultGeneration else {
            return
        }
        mainWindow?.showResults(text)
    }
}
