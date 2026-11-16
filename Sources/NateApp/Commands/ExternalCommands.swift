import AppKit
import Foundation
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：外部程序使用可执行路径与参数数组，文件和选区不会被拼入 shell。
    /// 参数说明: 无。
    /// 返回：明确展示实际动作后执行，输出保留为结果，不覆盖新输入。
    func configureRun() {
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
            let selection = active.buffer.selections.first?.range ?? ByteRange(0, 0)
            if values.contains(where: {
                $0.contains("${file}") || $0.contains("${directory}")
            })
                && active.url == nil
            {
                throw NateError.message("未命名文档没有磁盘路径，请先保存。")
            }
            let head = active.buffer.selections.first?.head ?? 0
            let row = active.buffer.text.lineNumber(at: head)
            let variables = [
                "file": active.url?.path ?? "",
                "directory": active.url?.deletingLastPathComponent().path ?? "",
                "name": active.name, "selection": active.buffer.text.text(in: selection),
                "line": String(row + 1),
                "column": String(
                    active.buffer.text.text(in: ByteRange(active.buffer.text.lineStart(row), head)).count + 1
                ),
            ]
            values = values.map {
                value in
                var value = value
                for (key, replacement) in variables {
                    value = value.replacingOccurrences(of: "${" + key + "}", with: replacement)
                }
                return value
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
            Task {
                do {
                    let result = try await fileIO.run {
                        try ProcessExecution.run(
                            executable: executable,
                            arguments: fixedArguments,
                            directory: workingDirectory
                        )
                    }
                    mainWindow?.showResults("退出状态 \(result.status)\n" + result.output)
                }
                catch {
                    SystemIntegration.alert("外部命令失败", error.localizedDescription)
                }
            }
        }
        catch {
            SystemIntegration.alert("运行配置", error.localizedDescription)
        }
    }
}
