import Foundation

public enum NewlineIndentationAction: Sendable, Equatable {
    case inherit
    case increase
    case decrease
    case expandPair
}

enum NewlineIndentationText {
    /// 业务作用：新行沿原缩进字节增减一个实际 Tab 层级，成对结构换行同时保留外层闭合行。
    /// 参数说明:
    /// - prefix: 当前插入点之前已经确认的原行前导空白。
    /// - ending: 当前文档真实插入换行。
    /// - action: 固定语言证据产生的新行结构动作。
    /// - settings: 当前语言的 Tab 宽度与新空白方式。
    /// - extra: 虚拟或部分 Tab 边缘需要继承的明确空格。
    /// - maximumBytes: 本目标仍有资格使用的完整输出容量。
    /// - budget: 全部光标共同拥有的继续资格。
    /// 返回：完整输入及其中的光标字节位置，容量、列数或执行资格不足时抛错。
    static func prepare(
        prefix: String,
        ending: String,
        action: NewlineIndentationAction,
        settings: TabSettings,
        extra: Int,
        maximumBytes: Int,
        budget: SelectionPreparationBudget
    ) throws -> (text: String, caret: Int) {
        var adjusted = prefix
        if action != .inherit {
            let bytes = Array(prefix.utf8)
            var column = 0
            for (index, byte) in bytes.enumerated() {
                if index & 255 == 0 {
                    try budget.check()
                }
                column += byte == 9 ? settings.width - column % settings.width : 1
                guard column <= 1_000_000 else {
                    throw NateError.message("语言缩进超过一百万列，原内容与选择保持原状。")
                }
            }
            if action == .decrease {
                let target = max(0, column - settings.width)
                var current = 0, end = 0
                while end < bytes.count {
                    if end & 255 == 0 {
                        try budget.check()
                    }
                    let next = current + (bytes[end] == 9 ? settings.width - current % settings.width : 1)
                    if next > target {
                        break
                    }
                    current = next
                    end += 1
                }
                adjusted =
                    String(decoding: bytes[..<end], as: UTF8.self)
                    + String(repeating: " ", count: target - current)
            }
            else {
                guard column <= 1_000_000 - settings.width else {
                    throw NateError.message("新行语言缩进超过一百万列，原内容与选择保持原状。")
                }
                if settings.useSpaces {
                    adjusted += String(repeating: " ", count: settings.width)
                }
                else {
                    let target = column + settings.width
                    while column + settings.width - column % settings.width <= target {
                        adjusted += "\t"
                        column += settings.width - column % settings.width
                    }
                    adjusted += String(repeating: " ", count: target - column)
                }
            }
        }
        let first = ending.utf8.count + adjusted.utf8.count + extra
        let trailing = action == .expandPair ? ending.utf8.count + prefix.utf8.count : 0
        // 所有追加空白和第二个换行先检查完整规模，不能先构建超量正文再丢弃后项。
        guard extra >= 0, first <= maximumBytes, trailing <= maximumBytes - first else {
            throw NateError.message("完整结构换行超过正文或输出容量。")
        }
        var text = ending + adjusted + String(repeating: " ", count: extra)
        if action == .expandPair {
            text += ending + prefix
        }
        try budget.check()
        return (text, first)
    }
}
