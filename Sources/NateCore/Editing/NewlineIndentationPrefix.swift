import Foundation

enum NewlineIndentationPrefix {
    /// 业务作用：在已确认的原空白前缀上增减有限层级，新增空白遵守当前 Tab 设置，原字节尽量保留。
    /// 参数说明:
    /// - prefix: 当前行或结构起始行的明确空白，不能包含正文字符。
    /// - levels: 增减的实际 Tab 层级，最多各 128 级。
    /// - settings: 当前语言的停靠宽度与新增空白方式。
    /// - budget: 全部换行目标共用的执行资格。
    /// 返回：完整空白前缀；非法字符、超过 1 MiB、超过一百万列或取消时拒绝整批输入。
    static func shift(
        _ prefix: String,
        levels: Int,
        settings: TabSettings,
        budget: SelectionPreparationBudget
    ) throws -> String {
        try budget.check()
        // 层级先验限制避免极值乘法溢出，原文规模先于字节副本确认。
        guard (-128...128).contains(levels), prefix.utf8.count <= 1_048_576 else {
            throw NateError.message("语言对齐超过前缀或层级容量，原内容与选择保持原状。")
        }
        let bytes = Array(prefix.utf8)
        var column = 0
        for (index, byte) in bytes.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            guard byte == 32 || byte == 9 else {
                throw NateError.message("语言对齐前缀必须只包含空格或 Tab。")
            }
            column += byte == 9 ? settings.width - column % settings.width : 1
            guard column <= 1_000_000 else {
                throw NateError.message("语言缩进超过一百万列，原内容与选择保持原状。")
            }
        }
        if levels < 0 {
            let target = max(0, column + settings.width * levels)
            var current = 0
            var end = 0
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
            return String(decoding: bytes[..<end], as: UTF8.self)
                + String(repeating: " ", count: target - current)
        }
        let target = column + settings.width * levels
        guard target <= 1_000_000 else {
            throw NateError.message("新行语言缩进超过一百万列，原内容与选择保持原状。")
        }
        if settings.useSpaces {
            return prefix + String(repeating: " ", count: target - column)
        }
        var adjusted = prefix
        while column + settings.width - column % settings.width <= target {
            try budget.check()
            adjusted += "\t"
            column += settings.width - column % settings.width
        }
        return adjusted + String(repeating: " ", count: target - column)
    }
}
