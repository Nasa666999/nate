import AppKit
import Foundation
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：外部程序使用可执行路径与参数数组，文件和选区不会被拼入 shell。
    /// 参数说明: 无。
    /// 返回：明确展示实际动作后执行，输出保留为结果，不覆盖新输入。
    func configureRun() {
        guard externalCommandTask == nil else {
            SystemIntegration.alert("已有外部命令运行", "可从工具菜单取消当前命令，完成后再启动下一条。")
            return
        }
        guard let active else {
            return
        }
        guard
            let executable = SystemIntegration.prompt(
                "运行外部命令",
                "输入程序绝对路径。程序参数将作为数据传递。",
                initial: "/usr/bin/wc"
            )
        else {
            return
        }
        guard
            let arguments = SystemIntegration.prompt(
                "参数数组",
                "输入 JSON 字符串数组。变量：${file}、${directory}、${name}、${selection}、${line}、${column}。",
                initial: "[\"-c\",\"${file}\"]"
            )
        else {
            return
        }
        do {
            var values = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
            let selection = active.buffer.primarySelection?.range ?? ByteRange(0, 0)
            if values.contains(where: {
                $0.contains("${file}") || $0.contains("${directory}")
            })
                && active.url == nil
            {
                throw NateError.message("未命名文档没有磁盘路径，请先保存。")
            }
            let head = active.buffer.primarySelection?.head ?? 0
            let row = active.buffer.text.lineNumber(at: head)
            var variables = [
                "name": active.name, "selection": active.buffer.text.text(in: selection),
                "line": String(row + 1),
                "column": String(
                    active.buffer.text.text(in: ByteRange(active.buffer.text.lineStart(row), head)).count + 1
                ),
            ]
            if let url = active.url {
                variables["file"] = url.path
                variables["directory"] = url.deletingLastPathComponent().path
            }
            values = try values.map {
                try CommandTemplate.expand($0, values: variables)
            }
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                throw NateError.message("程序路径无效或不可执行。")
            }
            let alert = NSAlert()
            alert.messageText = "执行外部程序"
            alert.informativeText =
                executable + "\n参数：" + String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
            alert.addButton(withTitle: "执行")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            let fixedArguments = values
            let workingDirectory = active.url?.deletingLastPathComponent()
            executeExternalCommand(executable, arguments: fixedArguments, directory: workingDirectory)
        }
        catch {
            SystemIntegration.alert("运行配置", error.localizedDescription)
        }
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
