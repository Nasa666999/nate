import Foundation
import NateCore
import NatePlatform
import NateUI

struct CLIArguments: Codable, Sendable {
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
            if value.hasPrefix("-n"), value != "-nosession", value.count > 2,
                let number = Int(value.dropFirst(2)), number > 0
            {
                line = number
                continue
            }
            if value.hasPrefix("-c"), value.count > 2,
                let number = Int(value.dropFirst(2)), number > 0
            {
                column = number
                continue
            }
            if value.hasPrefix("-p"), value.count > 2,
                let number = Int(value.dropFirst(2)), number >= 0
            {
                position = number
                continue
            }
            if value.hasPrefix("-l"), value.count > 2 {
                language = String(value.dropFirst(2))
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
                case "-n", "-c", "-p":
                    guard let number = Int(parameter), number >= (value == "-p" ? 0 : 1) else {
                        throw NateError.message("\(value) 的位置参数无效：\(parameter)")
                    }
                    if value == "-n" {
                        line = number
                    }
                    else if value == "-c" {
                        column = number
                    }
                    else {
                        position = number
                    }
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
    /// 参数说明:
    /// - request: 通过命令行或主实例入口取得的已规范化请求。
    /// 返回：真实文件按身份去重，位置使用明确的 UTF-8 和字形单位。
    func handleCLI(_ request: CLIArguments? = nil) async {
        do {
            let arguments = try request ?? CLIArguments(Array(CommandLine.arguments.dropFirst()))
            let window = mainWindow
            for url in arguments.files {
                guard let document = await openFile(url, in: window) else {
                    continue
                }
                try await applyCLISelection(arguments, to: document, in: window)
            }
            if arguments.files.isEmpty, arguments.language != nil, let active, mainWindow === window {
                try await applyCLISelection(arguments, to: active, in: window)
            }
            if let session = arguments.session {
                await loadSession(session)
            }
            if let folder = arguments.folders.first {
                await showFolder(folder, in: window)
            }
            refreshUI()
        }
        catch {
            SystemIntegration.alert("启动参数", error.localizedDescription)
        }
    }

    /// 业务作用：启动参数只作用于实际成功打开的文档，显式只读与监视沿用保存权限门禁。
    /// 参数说明:
    /// - arguments: 已验证的启动请求。
    /// - document: 本次成功打开或明确选择的文档。
    /// - window: 打开请求选定的窗口。
    /// 返回：语言和位置明确生效；非法字节边界拒绝，打开失败不会误改其他标签。
    func applyCLISelection(
        _ arguments: CLIArguments,
        to document: WorkspaceDocument,
        in window: EditorWindow?
    ) async throws {
        if let language = arguments.language {
            let id =
                registry?.language(language)?.id
                ?? registry?.languages.first(where: {
                    $0.name.caseInsensitiveCompare(language) == .orderedSame
                })?.id
            guard let id else {
                throw NateError.message("未知语言：\(language)")
            }
            document.language = id
            document.languageExplicit = true
        }
        if arguments.monitor && !document.monitoring {
            await toggleMonitoring(document)
        }
        else if arguments.readOnly {
            setReadOnly(document, value: true)
        }
        let range = document.buffer.text.lineRange(
            min(arguments.line - 1, document.buffer.text.lineCount - 1),
            includeEnding: false
        )
        let prefix = document.buffer.text.text(in: range).prefix(arguments.column - 1)
        let position = arguments.position ?? range.lower + prefix.utf8.count
        guard document.buffer.text.isBoundary(position) else {
            throw NateError.message("启动位置不在文件范围内，或位于 UTF-8 标量内部。")
        }
        // 等待监视保护期间同一窗口也可能换页，只定位仍显示当次正文的原编辑视图。
        if let window, isWorkspaceWindowAvailable(window), window.editor.document === document.buffer {
            window.editor.setCaret(position)
        }
    }
}
