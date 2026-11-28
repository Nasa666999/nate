import NateCore

extension PropertyLexing {
    /// 业务作用：在完整 SPICE 物理行上区分原生注释、分隔符、数字和三类词表，保存各区段的原始字节。
    /// 参数说明:
    /// - start: 物理行未跳过空白的起点。
    /// - end: 包含实际行结束符的原始末界。
    /// - rules: 当前语言定义的完整 SPICE 词表。
    /// 返回：完整行样式加入结果。容量、取消或截止失效时终止本次着色。
    mutating func spiceLine(_ start: Int, _ end: Int, rules: SpiceRules) throws {
        var position = start
        while position < end {
            try budget.consume()
            let begin = position
            let byte = bytes[position]
            position += 1
            let style: Int
            if byte == 42, begin == start || position < end && bytes[position] == 126 {
                // 注释样式持续到实际结束符之后，下一物理行从默认样式重新分类。
                position = end
                style = 8
            }
            else if Self.space(byte) {
                while position < end, Self.space(bytes[position]) {
                    try budget.consume()
                    position += 1
                }
                style = 0
            }
            else if Self.spiceDelimiter(byte) {
                style = 6
            }
            else if byte == 35 || (48...57).contains(byte) {
                position = try spiceNumberEnd(from: position, before: end)
                style = 5
            }
            else {
                while position < end, !Self.space(bytes[position]), !Self.spiceDelimiter(bytes[position]) {
                    try budget.consume()
                    position += 1
                }
                // 词表比较可在原词元内部遇到零值，样式起止仍保留其后的全部原字节。
                var word: [UInt8] = []
                for scalar in String(decoding: bytes[begin..<position], as: UTF8.self).unicodeScalars {
                    try budget.consume()
                    let value = scalar.value
                    let lowered = (65...90).contains(value) ? value + 32 : value
                    let unit = UInt8(truncatingIfNeeded: lowered)
                    guard unit != 0 else {
                        break
                    }
                    word.append(unit)
                }
                style = try rules.style(of: word, budget: &budget)
            }
            try emit(begin, position, style: style)
        }
    }

    /// 业务作用：保留数字字面与缩放后缀的字节范围，双点范围及带符号指数后按实际分隔符收束。
    /// 参数说明:
    /// - start: 已识别数字或 `#` 后的下一字节。
    /// - end: 当前物理行结束界。
    /// 返回：数字词元的完整原字节终点。扫描额度失效时终止本次着色。
    private mutating func spiceNumberEnd(from start: Int, before end: Int) throws -> Int {
        var position = start
        while position < end {
            let byte = bytes[position]
            let singlePoint = byte == 46 && (position + 1 == end || bytes[position + 1] != 46)
            guard !Self.space(byte) && (!Self.spiceDelimiter(byte) || singlePoint) else {
                break
            }
            try budget.consume()
            position += 1
        }
        if position < end, bytes[position - 1] == 69 || bytes[position - 1] == 101,
            bytes[position] == 43 || bytes[position] == 45
        {
            position += 1
            while position < end, !Self.space(bytes[position]), !Self.spiceDelimiter(bytes[position]) {
                try budget.consume()
                position += 1
            }
        }
        return position
    }

    /// 业务作用：同一 SPICE 分隔规则用于普通名称、数字和独立运算符，确保相邻样式按原字节划分。
    /// 参数说明:
    /// - byte: 当前物理行内尚未消费的实际字节。
    /// 返回：属于 SPICE 单字节分隔符时为真。
    private static func spiceDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 124:
            return true
        default:
            return false
        }
    }
}
