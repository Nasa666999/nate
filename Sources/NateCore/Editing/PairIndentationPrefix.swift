import Foundation

enum PairIndentationPrefix {
    /// 业务作用：结构字符与前导缩进必须共用一个明确替换范围，词法调用方不能越权覆盖正文。
    /// 参数说明:
    /// - prefix: 词法证据确认的完整新前导空白。
    /// - entry: 原普通选择的稳定身份与实际光标。
    /// - text: 与输入事务相同的固定正文。
    /// - settings: 当前语言的 Tab 停靠宽度。
    /// - allowsBody: 实际闭合花括号或方括号是否允许保留行内正文后调整行首。
    /// - remaining: 全部光标共用的前置原文字节与新增空白额度。
    /// - budget: 本次完整输入的继续资格与截止。
    /// 返回：原行起点及必须原字节保留的行内正文；非空选择、虚拟列、未授权正文或容量不足时整体失败。
    static func prepare(
        prefix: String,
        entry: SelectionEntry,
        text: PieceTree,
        settings: TabSettings,
        allowsBody: Bool,
        remaining: inout Int,
        budget: SelectionPreparationBudget
    ) throws -> (start: Int, body: String) {
        let selection = entry.selection
        guard selection.range.isEmpty, selection.virtualColumn == 0,
            prefix.utf8.count <= remaining
        else {
            throw NateError.message("结构字符对齐只允许普通空光标及 1 MiB 以内的完整缩进。")
        }
        // 在构建逐目标字符串前限制整批新增空白，外部解析器不能令核心先分配超量中间结果。
        remaining -= prefix.utf8.count
        var column = 0
        for (index, byte) in prefix.utf8.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            guard byte == 9 || byte == 32 else {
                throw NateError.message("结构字符对齐不能写入空格和 Tab 以外的前缀。")
            }
            column += byte == 9 ? settings.width - column % settings.width : 1
            guard column <= 1_000_000 else {
                throw NateError.message("结构字符缩进超过一百万列。")
            }
        }
        let start = text.lineStart(text.lineNumber(at: selection.head))
        guard selection.head - start <= remaining else {
            throw NateError.message("结构字符的共享前置原文读取超过 1 MiB。")
        }
        remaining -= selection.head - start
        var end = start
        while end < selection.head {
            if end & 255 == 0 {
                try budget.check()
            }
            guard let byte = text.byte(at: end), byte == 9 || byte == 32 else {
                break
            }
            end += 1
        }
        guard allowsBody || end == selection.head else {
            throw NateError.message("当前结构字符不能调整带正文的前导范围。")
        }
        // 只接受调用方提供的新空白，扩大范围中的正文必须由同一原树读取，不能被外部计划替换。
        let body = text.text(in: ByteRange(end, selection.head))
        try budget.check()
        return (start, body)
    }
}
