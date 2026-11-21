import Foundation

public enum RunCommandVariables {
    public static let supported: Set<String> = [
        "file", "directory", "name", "stem", "extension", "selection", "word", "lineText", "line", "column",
    ]
    public static let maximumValueBytes = 1_048_576

    /// 业务作用：只从固定正文与主光标提取实际引用的变量，未引用的巨型行或选区不被复制。
    /// 参数说明:
    /// - text: 准备命令时固定的完整正文快照。
    /// - selection: 与快照一致的完整选择身份，行列使用主项。
    /// - displayName: 未命名文档也可使用的当前名称。
    /// - file: 当前实际文件路径，未命名文档为空。
    /// - requested: 原始模板明确引用的规范变量名。
    /// - tabWidth: 计算主光标逻辑列的 Tab 停靠宽度。
    /// - wordBoundaries: 当前词变量固定采用的来源视图规则。
    /// - permit: 读取和列计算仍属于本次命令准备的资格。
    /// 返回：完整原文值；未知、缺失路径、歧义选择、超量或取消拒绝，不截断或改写正文。
    public static func values(
        text: PieceTree,
        selection: SelectionState,
        displayName: String,
        file: URL?,
        requested: Set<String>,
        tabWidth: Int = 4,
        wordBoundaries: WordBoundarySettings = WordBoundarySettings(),
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> [String: String] {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard requested.count <= supported.count, requested.isSubset(of: supported),
            (1...32).contains(tabWidth)
        else {
            throw NateError.message("运行命令包含未知变量或无效 Tab 宽度。")
        }
        let primary = selection.primary.selection
        guard text.isBoundary(primary.anchor), text.isBoundary(primary.head) else {
            throw NateError.message("运行命令的主光标不再属于原正文，未读取变量。")
        }
        var values: [String: String] = [:]
        let name = file?.lastPathComponent ?? displayName
        for key in requested.intersection(["name", "stem", "extension"]) {
            let value: String
            switch key {
            case "stem": value = (name as NSString).deletingPathExtension
            case "extension": value = (name as NSString).pathExtension
            default: value = name
            }
            guard value.utf8.count <= maximumValueBytes else {
                throw NateError.message("运行命令的文件名称变量超过 1 MiB。")
            }
            values[key] = value
        }
        if !requested.isDisjoint(with: ["file", "directory"]) {
            // 未命名或远程主机没有可直接交给本地程序的磁盘身份，不能以空字符串猜测路径。
            guard let file, file.isFileURL, file.host == nil || file.host == "" || file.host == "localhost",
                file.user == nil, file.password == nil, file.port == nil, !file.path.utf8.contains(0),
                file.path.utf8.count <= maximumValueBytes
            else {
                throw NateError.message("此运行命令需要当前文件的本地磁盘路径，请先保存或检查路径。")
            }
            if requested.contains("file") {
                values["file"] = file.path
            }
            if requested.contains("directory") {
                values["directory"] = file.deletingLastPathComponent().path
            }
        }
        if !requested.isDisjoint(with: ["selection", "word"]) {
            // 多选、矩形和虚拟列不能被当成一段完整选区，避免传递与用户可见选择不同的正文。
            guard selection.entries.count == 1, selection.shape == .stream, primary.virtualColumn == 0 else {
                throw NateError.message("选区或当前词变量需要一个普通连续选择；多选、矩形或虚拟列未转成路径参数。")
            }
            guard primary.range.count <= maximumValueBytes else {
                throw NateError.message("运行命令的完整选区超过 1 MiB。")
            }
            if requested.contains("selection") || !primary.range.isEmpty {
                let selected = text.text(in: primary.range)
                if requested.contains("selection") {
                    values["selection"] = selected
                }
                if requested.contains("word"), !primary.range.isEmpty {
                    values["word"] = selected
                }
            }
            if requested.contains("word"), primary.range.isEmpty {
                switch text.wordSelection(
                    at: primary.head,
                    maximumScalars: 262_144,
                    wordBoundaries: wordBoundaries
                ) {
                case .noWord: values["word"] = ""
                case .word(let range):
                    guard range.count <= maximumValueBytes else {
                        throw NateError.message("运行命令的完整当前词超过 1 MiB。")
                    }
                    values["word"] = text.text(in: range)
                case .exceedsLimit:
                    throw NateError.message("运行命令的当前词超过完整读取预算。")
                }
            }
        }
        let line = text.lineNumber(at: primary.head)
        if requested.contains("line") {
            values["line"] = String(line + 1)
        }
        if requested.contains("lineText") {
            let range = text.lineRange(line, includeEnding: false)
            guard range.count <= maximumValueBytes else {
                throw NateError.message("运行命令的当前完整行超过 1 MiB。")
            }
            values["lineText"] = text.text(in: range)
        }
        if requested.contains("column") {
            values["column"] = String(
                try column(
                    text: text,
                    primary: primary,
                    start: text.lineStart(line),
                    tabWidth: tabWidth,
                    permit: permit
                )
            )
        }
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        return values
    }

    /// 业务作用：主光标列按完整字形与 Tab 停靠计算，不能以 UTF-8 字节或部分字形近似可见位置。
    /// 参数说明:
    /// - text: 固定正文快照。
    /// - primary: 当前明确的主光标几何。
    /// - start: 当前逻辑行的真实字节起点。
    /// - tabWidth: 当前 Tab 停靠宽度。
    /// - permit: 本次准备仍有效的资格。
    /// 返回：一为起点的准确逻辑列；字形读取预算、取消或边界不足拒绝整份准备。
    private static func column(
        text: PieceTree,
        primary: TextSelection,
        start: Int,
        tabWidth: Int,
        permit: @Sendable () -> Bool
    ) throws -> Int {
        var navigation = try GraphemeNavigation(text: text)
        var position = start, column = 0
        while position < primary.head {
            guard permit() else {
                throw CancellationError()
            }
            let next = try navigation.boundary(from: position, forward: true)
            guard next <= primary.head else {
                throw NateError.message("运行命令的光标位于完整字形内部，未猜测列号。")
            }
            column += text.byte(at: position) == 9 ? tabWidth - column % tabWidth : 1
            position = next
        }
        return column + primary.virtualColumn + 1
    }
}
