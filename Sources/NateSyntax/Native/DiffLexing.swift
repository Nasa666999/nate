import Foundation

extension PropertyLexing {
    /// 业务作用：按标记优先级区分差异文件头、位置与增删内容，不执行补丁中的命令。
    /// 参数说明:
    /// - start: 当前物理行起点。
    /// - end: 包含真实结束符的末边界。
    /// 返回：完整行的固定差异样式；CRLF 与内嵌 NUL 保持各自原始语义。
    mutating func diffLine(_ start: Int, _ end: Int) throws {
        let finish = end > start && (bytes[end - 1] == 10 || bytes[end - 1] == 13) ? end - 1 : end
        let first: UInt8 = start < finish ? bytes[start] : 0
        let style: Int
        if try diffPrefix("diff ", start: start, end: finish)
            || diffPrefix("Index: ", start: start, end: finish)
        {
            style = 2
        }
        else if try diffPrefix("---", start: start, end: finish),
            start + 3 == finish || bytes[start + 3] != 45
        {
            let fourth: UInt8 = start + 3 < finish ? bytes[start + 3] : 0
            if try fourth == 32 && diffPosition(start + 4, end: finish) || fourth == 13 || fourth == 10 {
                style = 4
            }
            else {
                style = fourth == 32 ? 3 : 5
            }
        }
        else if try diffPrefix("+++ ", start: start, end: finish) {
            style = try diffPosition(start + 4, end: finish) ? 4 : 3
        }
        else if try diffPrefix("====", start: start, end: finish) {
            style = 3
        }
        else if try diffPrefix("***", start: start, end: finish) {
            let fourth: UInt8 = start + 3 < finish ? bytes[start + 3] : 0
            style = try fourth == 42 || fourth == 32 && diffPosition(start + 4, end: finish) ? 4 : 3
        }
        else if try diffPrefix("? ", start: start, end: finish) {
            style = 3
        }
        else if first == 64 || first >= 48 && first <= 57 {
            style = 4
        }
        else if try diffPrefix("++", start: start, end: finish) {
            style = 8
        }
        else if try diffPrefix("+-", start: start, end: finish) {
            style = 9
        }
        else if try diffPrefix("-+", start: start, end: finish) {
            style = 10
        }
        else if try diffPrefix("--", start: start, end: finish) {
            style = 11
        }
        else if first == 45 || first == 60 {
            style = 5
        }
        else if first == 43 || first == 62 {
            style = 6
        }
        else if first == 33 {
            style = 7
        }
        else {
            style = first == 32 ? 0 : 1
        }
        try emit(start, end, style: style)
    }

    /// 业务作用：差异标记按原始 ASCII 前缀匹配，不进行规范等价匹配或命令解析。
    /// 参数说明:
    /// - text: 固定标记。
    /// - start: 物理行起点。
    /// - end: 行缓冲区末边界。
    /// 返回：完整前缀一致时为真，实际比较计入共同预算。
    mutating func diffPrefix(_ text: String, start: Int, end: Int) throws -> Bool {
        let pattern = Array(text.utf8)
        guard pattern.count <= end - start else {
            return false
        }
        for index in pattern.indices {
            try budget.consume()
            if bytes[start + index] != pattern[index] {
                return false
            }
        }
        return true
    }

    /// 业务作用：上下文差异的位置要求非零十进制前缀且没有路径斜线，不用整数转换截断长数字。
    /// 参数说明:
    /// - start: 标记后的候选数字起点。
    /// - end: 行缓冲区末边界。
    /// 返回：非零位置候选成立时为真；首个 NUL 终止位置证据，原正文仍完整保留。
    mutating func diffPosition(_ start: Int, end: Int) throws -> Bool {
        var limit = start
        while limit < end, bytes[limit] != 0 {
            try budget.consume()
            if bytes[limit] == 47 {
                return false
            }
            limit += 1
        }
        var cursor = start
        while cursor < limit, Self.space(bytes[cursor]) {
            try budget.consume()
            cursor += 1
        }
        if cursor < limit, bytes[cursor] == 43 || bytes[cursor] == 45 {
            cursor += 1
        }
        var nonzero = false
        while cursor < limit, bytes[cursor] >= 48 && bytes[cursor] <= 57 {
            try budget.consume()
            nonzero = nonzero || bytes[cursor] != 48
            cursor += 1
        }
        return nonzero
    }
}
