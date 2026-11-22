import Foundation

extension YAMLLexing {
    /// 业务作用：映射值按块文本、注释、引用、关键字和数字外观的固定顺序分类，保留整个原值范围。
    /// 参数说明:
    /// - start: 冒号之后的原范围起点。
    /// - end: 当前物理行末边界。
    /// - indent: 当前行开头的空格数量。
    /// 返回：当前值的完整样式及必要块文本父级；原 NUL 和结束符不被移除。
    mutating func value(_ start: Int, _ end: Int, indent: Int) throws {
        var cursor = start
        while cursor < end, Self.white(byte(cursor)) {
            try budget.consume()
            cursor += 1
        }
        var cut = end
        while cut > cursor, Self.white(byte(cut - 1)) {
            try budget.consume()
            cut -= 1
        }
        if valueByte(cursor, cut: cut, end: end) == 124 || valueByte(cursor, cut: cut, end: end) == 62 {
            cursor += 1
            if [43, 45].contains(valueByte(cursor, cut: cut, end: end)) {
                cursor += 1
            }
            while cursor < end, Self.white(valueByte(cursor, cut: cut, end: end)) {
                try budget.consume()
                cursor += 1
            }
            if valueByte(cursor, cut: cut, end: end) == 0 {
                state.textIndent = indent
            }
            else if valueByte(cursor, cut: cut, end: end) == 35 {
                state.textIndent = indent
                try paint(cursor, end, style: 1)
            }
            else {
                try paint(start, end, style: 8)
            }
            return
        }
        if valueByte(cursor, cut: cut, end: end) == 35 {
            try paint(cursor, end, style: 1)
            return
        }
        var comment = cursor
        var inQuotes = false
        while comment < end {
            try budget.consume()
            let current = valueByte(comment, cut: cut, end: end)
            if current == 39 || current == 34 {
                inQuotes.toggle()
            }
            if current == 35, Self.white(valueByte(comment - 1, cut: cut, end: end)), !inQuotes {
                break
            }
            comment += 1
        }
        let style: UInt8
        if [38, 42].contains(valueByte(cursor, cut: cut, end: end)) {
            style = 5
        }
        else if try keyword(cursor, comment, cut: cut, end: end) {
            style = 3
        }
        else {
            let first = cursor
            var numeric = true
            while cursor < comment, valueByte(cursor, cut: cut, end: end) != 0 {
                try budget.consume()
                let current = valueByte(cursor, cut: cut, end: end)
                if !((48...57).contains(current) || [45, 46, 44, 32].contains(current)) {
                    numeric = false
                    break
                }
                cursor += 1
            }
            style = numeric && cursor > first ? 4 : 0
        }
        try paint(start, comment, style: style)
        if comment < end {
            try paint(comment, end, style: 1)
        }
    }

    /// 业务作用：值末尾空白的虚拟终止位置参与基准分类，但不改变正文中的任何字节。
    /// 参数说明:
    /// - offset: 当前候选原字节位置。
    /// - cut: 去尾空白后的虚拟终止点。
    /// - end: 当前物理行末边界。
    /// 返回：虚拟终止点及范围之外为零，其余仍为原字节。
    func valueByte(_ offset: Int, cut: Int, end: Int) -> UInt8 {
        offset == cut || offset >= end ? 0 : byte(offset)
    }

    /// 业务作用：布尔等词条采用至多九十九个原字节及 C 字符串终止语义，组合序列不被规范等价合并。
    /// 参数说明:
    /// - start: 去除前导空白的值起点。
    /// - comment: 注释起点，没有注释时为行末。
    /// - cut: 去尾空白后的虚拟终止点。
    /// - end: 当前物理行末边界。
    /// 返回：完整候选原字节命中词表时为真，超长及空候选为假。
    mutating func keyword(_ start: Int, _ comment: Int, cut: Int, end: Int) throws -> Bool {
        guard comment > start else {
            return false
        }
        var last = comment
        while last > start, valueByte(last - 1, cut: cut, end: end) == 32 {
            try budget.consume()
            last -= 1
        }
        guard last - start <= 99 else {
            return false
        }
        var candidate: [UInt8] = []
        for offset in start..<last {
            try budget.consume()
            let current = valueByte(offset, cut: cut, end: end)
            if current == 0 {
                break
            }
            candidate.append(current)
        }
        return rules.words.contains(Data(candidate))
    }
}
