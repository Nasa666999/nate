enum RubyCharacterLiteral {
    /// 业务作用：区分实际问号字符字面与表达式操作符，转义中的括号和关键字不能冒充语法边界。
    /// 参数说明:
    /// - bytes: 当前物理行的不含结束符的原始 UTF-8。
    /// - question: 已在表达式位置找到的问号原字节。
    /// - check: 所有光标或高亮词元共用的计算资格。
    /// 返回：合法字符字面实际覆盖的结束位置；多字符名称、空白或缺少内容时为空。
    static func end(in bytes: [UInt8], after question: Int, check: () throws -> Void) throws -> Int? {
        let original = question + 1
        guard original < bytes.count, ![9, 10, 11, 12, 13, 32].contains(bytes[original]) else {
            return nil
        }
        let initial = bytes[original]
        if initial != 92 {
            let end = min(bytes.count, original + RubyIndentationLexer.scalarLength(initial))
            let wordLike = RubyIndentationLexer.namePart(initial)
            if wordLike, end < bytes.count, RubyIndentationLexer.namePart(bytes[end]) {
                return nil
            }
            return end
        }
        var start = original
        while start < bytes.count {
            try check()
            guard bytes[start] == 92, start + 1 < bytes.count else {
                return min(bytes.count, start + RubyIndentationLexer.scalarLength(bytes[start]))
            }
            let key = bytes[start + 1]
            if [67, 77].contains(key), start + 2 < bytes.count, bytes[start + 2] == 45 {
                start += 3
            }
            else if key == 99 {
                start += 2
            }
            else {
                return escapedEnd(in: bytes, start: start + 1, key: key)
            }
        }
        return bytes.count
    }

    /// 业务作用：按原生字符形式保留固定长度、花括号和八进制转义的实际消费范围。
    /// 参数说明:
    /// - bytes: 当前真实物理行。
    /// - start: 反斜杠之后的第一个原字节。
    /// - key: 已确认的转义选择字节。
    /// 返回：最多读取该转义形式允许的原数字，未相邻的闭合符不被吞入。
    private static func escapedEnd(in bytes: [UInt8], start: Int, key: UInt8) -> Int {
        var index = start + 1
        let maximum: Int
        let octal: Bool
        let braced = key == 117 && index < bytes.count && bytes[index] == 123
        if braced {
            index += 1
            maximum = 7
            octal = false
        }
        else if key == 117 || key == 120 {
            maximum = key == 117 ? 4 : 2
            octal = false
        }
        else if (48...55).contains(key) {
            maximum = 2
            octal = true
        }
        else {
            return min(bytes.count, start + RubyIndentationLexer.scalarLength(key))
        }
        let limit = min(bytes.count, index + maximum)
        while index < limit {
            let byte = bytes[index]
            let digit =
                octal
                ? (48...55).contains(byte)
                : (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            if !digit {
                return braced && byte == 125 ? index + 1 : index
            }
            index += 1
        }
        return index
    }
}
