import Foundation
import NateCore
import NatePlatform

struct CLIArguments {
    var files: [URL] = []
    var language: String?
    var line = 1
    var column = 1
    var position: Int?
    var readOnly = false
    var monitor = false
    var noRestore = false
    var folders: [URL] = []
    var session: URL?
    static let help = """
        Nate — 原生 macOS 文本与代码编辑器
        用法：nate [选项] [--] 文件…
          -l 名称 / -udl 名称     显式选择语言
          -n 行号 -c 列号        从 1 开始的逻辑行与字形列
          -p UTF8字节位置        从 0 开始，必须位于标量边界；优先于行列
          -ro                    编辑器只读
          --monitor              只读监视文件
          --no-restore           本次启动不恢复会话
          -openSession 文件      打开 Nate 命名会话
          -openFoldersAsWorkspace 目录…  显示目录工作区
          --                     后续参数全部按文件名解释
          --help                 显示帮助
        Windows 系统托盘参数不适用于 macOS，会明确拒绝。
        """

    /// 业务作用：将路径和启动开关分开解析，未知开关不静默忽略。
    /// 参数说明:
    /// - arguments: 不含主程序名的命令行参数。
    /// 返回：明确的启动请求；缺少参数或非法位置时失败。
    init(_ arguments: [String]) throws {
        var i = 0
        var literal = false
        while i < arguments.count {
            let value = arguments[i]
            i += 1
            if literal {
                files.append(URL(fileURLWithPath: value))
                continue
            }
            if value == "--" {
                literal = true
                continue
            }
            switch value {
            case "-ro", "--read-only": readOnly = true
            case "--monitor":
                monitor = true
                readOnly = true
            case "--no-restore", "-nosession": noRestore = true
            case "-l", "-udl", "-n", "-c", "-p", "-openSession":
                guard i < arguments.count else {
                    throw NateError.message("\(value) 缺少参数。")
                }
                let parameter = arguments[i]
                i += 1
                switch value {
                case "-l", "-udl": language = parameter
                case "-n": line = max(1, Int(parameter) ?? 1)
                case "-c": column = max(1, Int(parameter) ?? 1)
                case "-p": position = Int(parameter)
                default: session = URL(fileURLWithPath: parameter)
                }
            case "-openFoldersAsWorkspace":
                folders = arguments[i...].map {
                    URL(fileURLWithPath: $0)
                }
                i = arguments.count
            default:
                if value.hasPrefix("-psn_") {
                    continue
                }
                if value.hasPrefix("-") {
                    throw NateError.message("不支持的启动参数：\(value)。请使用 --help。")
                }
                files.append(URL(fileURLWithPath: value))
            }
        }
    }
}

extension ApplicationController {
    /// 业务作用：把命令行打开与定位请求合并到现有工作区。
    /// 参数说明: 无。
    /// 返回：真实文件按身份去重，位置使用明确的 UTF-8 和字形单位。
    func handleCLI() async {
        do {
            let arguments = try CLIArguments(Array(CommandLine.arguments.dropFirst()))
            for url in arguments.files {
                await openFile(url)
                guard let active else {
                    continue
                }
                if let language = arguments.language {
                    guard registry?.language(language) != nil else {
                        throw NateError.message("未知语言：\(language)")
                    }
                    active.language = language
                    active.languageExplicit = true
                }
                active.buffer.isReadOnly = arguments.readOnly
                active.monitoring = arguments.monitor
                let range = active.buffer.text.lineRange(
                    min(arguments.line - 1, active.buffer.text.lineCount - 1),
                    includeEnding: false
                )
                let prefix = active.buffer.text.text(in: range).prefix(arguments.column - 1)
                mainWindow?.editor.setCaret(arguments.position ?? range.lower + prefix.utf8.count)
            }
            if let session = arguments.session {
                await loadSession(session)
            }
            if let folder = arguments.folders.first {
                await showFolder(folder)
            }
            refreshUI()
        }
        catch {
            SystemIntegration.alert("启动参数", error.localizedDescription)
        }
    }
}
