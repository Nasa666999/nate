import NateCore

struct RubyCodePosition: Equatable, Sendable {
    typealias Token = RubyIndentationLexer.Token

    var expectsOperand: Bool
    private var qualified = false

    /// 业务作用：建立一个与外层代码独立的表达式读取位置。
    /// 参数说明:
    /// - expectsOperand: 首个词元是否从等待值的位置读取。
    /// 返回：尚无成员限定符的读取状态。
    init(expectsOperand: Bool = true) {
        self.expectsOperand = expectsOperand
    }

    /// 业务作用：在实际值或紧邻命令参数位置允许正则和百分号字面。
    /// 参数说明:
    /// - bytes: 当前物理行的完整原字节。
    /// - index: 待识别的原字节位置。
    /// 返回：当前位置满足表达式规则时为真。
    func acceptsLiteral(in bytes: [UInt8], at index: Int) -> Bool {
        let following = index + 1 < bytes.count ? bytes[index + 1] : 0
        return expectsOperand
            || (index > 0 && RubyIndentationLexer.blank(bytes[index - 1])
                && !RubyIndentationLexer.blank(following) && following != 0 && following != 61)
    }

    /// 业务作用：已识别的完整值结束操作数需求和成员上下文。
    /// 参数说明: 无。
    /// 返回：下一个独立词元从已有值之后开始解释。
    mutating func consumeValue() {
        expectsOperand = false
        qualified = false
    }

    /// 业务作用：符号或问号字符字面整体消费，内部标点不会改变外层括号或插值深度。
    /// 参数说明:
    /// - bytes: 当前物理行不含结束符的原字节。
    /// - index: 待确认的原字节位置。
    /// - check: 本次读取的共同继续资格。
    /// 返回：已确认的字面及原端点；其它位置保持原扫描状态。
    mutating func takeStandaloneLiteral(
        in bytes: [UInt8],
        from index: inout Int,
        check: () throws -> Void
    ) throws -> Token? {
        let start = index
        let byte = bytes[start]
        let style: RubyHighlightStyle
        let end: Int
        if byte == 58, let after = try RubyHighlightWords.symbolEnd(in: bytes, at: start, check: check) {
            style = .symbol
            end = after
        }
        else if byte == 63, acceptsLiteral(in: bytes, at: start),
            let after = try RubyCharacterLiteral.end(in: bytes, after: start, check: check)
        {
            style = .number
            end = after
        }
        else {
            return nil
        }
        index = end
        consumeValue()
        return Token(kind: .operand, span: ByteRange(start, end), highlightStyle: style)
    }

    /// 业务作用：为主代码及字面插值复用相同的原始名称、变量和操作符边界。
    /// 参数说明:
    /// - bytes: 当前物理行不含结束符的原字节。
    /// - index: 待消费的首字节，调用者已处理空白和字面开端。
    /// - check: 本次读取的共同继续资格。
    /// 返回：下一个完整原词元及后继表达式位置。
    mutating func take(in bytes: [UInt8], from index: inout Int, check: () throws -> Void) throws -> Token {
        let start = index
        let byte = bytes[start]
        let following = start + 1 < bytes.count ? bytes[start + 1] : 0
        if RubyIndentationLexer.namePart(byte) {
            index += 1
            while index < bytes.count, RubyIndentationLexer.namePart(bytes[index]) {
                if index & 255 == 0 {
                    try check()
                }
                index += 1
            }
            let suffix = index < bytes.count ? bytes[index] : 0
            let after = index + 1 < bytes.count ? bytes[index + 1] : 0
            let label = suffix == 58 && after != 58
            let predicate = suffix == 63 || suffix == 33 && after != 61
            if label || predicate {
                index += 1
            }
            let word =
                qualified || label || predicate || index - start > 8
                ? nil
                : RubyIndentationLexer.Word(rawValue: String(decoding: bytes[start..<index], as: UTF8.self))
            expectsOperand = label || RubyIndentationLexer.prefixesExpression(word)
            qualified = false
            return Token(kind: word.map(Token.Kind.word) ?? .operand, span: ByteRange(start, index))
        }
        if byte == 36 || byte == 64 {
            index += 1
            if index < bytes.count,
                bytes[index] == 64
                    || byte == 36 && !RubyIndentationLexer.namePart(bytes[index])
                        && !RubyIndentationLexer.blank(bytes[index])
            {
                index = min(bytes.count, index + RubyIndentationLexer.scalarLength(bytes[index]))
            }
            while index < bytes.count, RubyIndentationLexer.namePart(bytes[index]) {
                if index & 255 == 0 {
                    try check()
                }
                index += 1
            }
            consumeValue()
            return Token(kind: .operand, span: ByteRange(start, index))
        }
        let assignment =
            byte == 61 && ![61, 62, 126].contains(following)
            && (index == 0 || ![33, 60, 61, 62].contains(bytes[index - 1]))
        index += 1
        expectsOperand =
            assignment
            || [33, 37, 38, 40, 42, 43, 44, 45, 47, 58, 59, 60, 61, 62, 91, 94, 123, 124, 126]
                .contains(byte)
        qualified = byte == 46 || byte == 58
        return Token(kind: assignment ? .assignment : .symbol(byte), span: ByteRange(start, index))
    }
}
