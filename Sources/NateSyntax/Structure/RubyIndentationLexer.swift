import NateCore

struct RubyIndentationLexer: Equatable, Sendable {
    enum Word: String {
        case conditional = "if"
        case unless, elsif
        case fallback = "else"
        case choice = "case"
        case when, then
        case pattern = "in"
        case looping = "while"
        case until
        case iteration = "for"
        case begin, rescue, ensure
        case def, module
        case classBody = "class"
        case block = "do"
        case end
        case and, or, not
        case returning = "return"
        case yielding = "yield"
    }

    struct Token {
        enum Kind {
            case word(Word)
            case operand
            case assignment
            case symbol(UInt8)
        }

        let kind: Kind
        let span: ByteRange
        var highlightStyle: RubyHighlightStyle? = nil

        /// 业务作用：结构操作只接受不属于原始字面范围的代码词元。
        /// 参数说明: 无。
        /// 返回：原词元为字面的任意组成部分时为真。
        var literal: Bool {
            highlightStyle != nil
        }
    }

    struct Row {
        let tokens: [Token]
        let beginsInLiteral: Bool
        let holdsLiteral: Bool
        let commentStart: Int?
        let entirelyOpaque: Bool
        var opaqueStyle: RubyHighlightStyle? = nil
        var endingStyle: RubyHighlightStyle? = nil
        var heredocEnd: Int? = nil
    }

    private var literal = RubyLiteralState()
    private var heredocs: [RubyHeredoc] = []
    private var documentation = false
    private var dataSection = false
    private var literalStyle: RubyHighlightStyle? = nil

    /// 业务作用：逐行保持 Ruby 真实字面、文档注释和数据边界，只向结构缩进交付可消费的代码词元。
    /// 参数说明:
    /// - bytes: 同一固定正文中当前物理行的完整原字节，排除结束符。
    /// - check: 全部目标、词法及最终提交共用的截止和继续资格。
    /// 返回：按真实相对偏移升序的词元以及仍处于隔离状态的边界；超量或取消拒绝整批。
    mutating func row(_ bytes: [UInt8], check: () throws -> Void) throws -> Row {
        try check()
        if let document = heredocs.first {
            let close = document.closingOffset(in: bytes)
            if close != nil {
                heredocs.removeFirst()
            }
            var row = Self.opaqueRow(document.style, ending: close == nil ? document.style : nil)
            row.heredocEnd = close
            return row
        }
        if dataSection {
            return Self.opaqueRow(.data, ending: .data)
        }
        if documentation {
            let ends = Self.directive("=end", in: bytes)
            if ends {
                documentation = false
            }
            return Self.opaqueRow(.documentation, ending: ends ? nil : .documentation)
        }
        if !literal.isOpen, Self.directive("=begin", in: bytes) {
            documentation = true
            return Self.opaqueRow(.documentation, ending: .documentation)
        }
        if !literal.isOpen, bytes.elementsEqual("__END__".utf8) {
            dataSection = true
            return Self.opaqueRow(.data, ending: .data)
        }
        let beginsInLiteral = literal.isOpen
        var tokens: [Token] = []
        var index = 0
        var commentStart: Int?
        var expectsOperand = !beginsInLiteral
        var qualified = false
        if beginsInLiteral {
            try literal.advance(in: bytes, from: &index, check: check)
            if index > 0 {
                tokens.append(Token(kind: .operand, span: ByteRange(0, index), highlightStyle: literalStyle))
            }
            if !literal.isOpen {
                literalStyle = nil
            }
        }
        while index < bytes.count, !literal.isOpen {
            try check()
            let byte = bytes[index]
            if Self.blank(byte) {
                index += 1
                continue
            }
            if byte == 35 {
                commentStart = index
                break
            }
            // 词元数量在写入前复验，缺少任一目标的上下文时拒绝整次结构输入。
            guard tokens.count < 65_536 else {
                throw NateError.message("Ruby 结构缩进单行超过 65536 个词元。")
            }
            let start = index
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            let possibleArgument =
                index > 0 && Self.blank(bytes[index - 1]) && !Self.blank(following)
                && following != 0 && following != 61
            let acceptsLiteral = expectsOperand || possibleArgument
            if byte == 58, let after = try RubyHighlightWords.symbolEnd(in: bytes, at: index, check: check) {
                index = after
                tokens.append(Token(kind: .operand, span: ByteRange(start, index), highlightStyle: .symbol))
                expectsOperand = false
                qualified = false
                continue
            }
            if acceptsLiteral,
                let (document, after) = try RubyHeredoc.opening(in: bytes, at: index, check: check)
            {
                guard heredocs.count < 256 else {
                    throw NateError.message("Ruby 同行 heredoc 声明超过 256 个。")
                }
                heredocs.append(document)
                index = after
                tokens.append(
                    Token(kind: .operand, span: ByteRange(start, index), highlightStyle: .heredocDelimiter)
                )
                expectsOperand = false
                qualified = false
                continue
            }
            if let (delimiter, after) = RubyLiteralState.opener(in: bytes, at: index, pattern: acceptsLiteral)
            {
                literal.begin(delimiter)
                index = after
                let style = RubyHighlightStyle.literal(bytes[start..<after])
                try literal.advance(in: bytes, from: &index, check: check)
                literalStyle = literal.isOpen ? style : nil
                tokens.append(Token(kind: .operand, span: ByteRange(start, index), highlightStyle: style))
                expectsOperand = false
                qualified = false
                continue
            }
            if byte == 63, expectsOperand, following != 0, !Self.blank(following) {
                index += 1
                if bytes[index] == 92, index + 1 < bytes.count {
                    index += 1
                }
                index = min(bytes.count, index + Self.scalarLength(bytes[index]))
                tokens.append(Token(kind: .operand, span: ByteRange(start, index), highlightStyle: .number))
                expectsOperand = false
                qualified = false
                continue
            }
            if Self.namePart(byte) {
                index += 1
                while index < bytes.count, Self.namePart(bytes[index]) {
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
                    ? nil : Word(rawValue: String(decoding: bytes[start..<index], as: UTF8.self))
                tokens.append(
                    Token(kind: word.map(Token.Kind.word) ?? .operand, span: ByteRange(start, index))
                )
                expectsOperand = label || Self.prefixesExpression(word)
                qualified = false
                continue
            }
            if byte == 36 || byte == 64 {
                index += 1
                if index < bytes.count,
                    bytes[index] == 64
                        || byte == 36 && !Self.namePart(bytes[index])
                            && !Self.blank(bytes[index])
                {
                    index = min(bytes.count, index + Self.scalarLength(bytes[index]))
                }
                while index < bytes.count, Self.namePart(bytes[index]) {
                    if index & 255 == 0 {
                        try check()
                    }
                    index += 1
                }
                tokens.append(Token(kind: .operand, span: ByteRange(start, index)))
                expectsOperand = false
                qualified = false
                continue
            }
            let assignment =
                byte == 61 && ![61, 62, 126].contains(following)
                && (index == 0 || ![33, 60, 61, 62].contains(bytes[index - 1]))
            index += 1
            tokens.append(
                Token(kind: assignment ? .assignment : .symbol(byte), span: ByteRange(start, index))
            )
            expectsOperand =
                assignment
                || [33, 37, 38, 40, 42, 43, 44, 45, 47, 58, 59, 60, 61, 62, 91, 94, 123, 124, 126]
                    .contains(byte)
            qualified = byte == 46 || byte == 58
        }
        return Row(
            tokens: tokens,
            beginsInLiteral: beginsInLiteral,
            holdsLiteral: literal.isOpen,
            commentStart: commentStart,
            entirelyOpaque: false,
            endingStyle: literalStyle ?? heredocs.first?.style
        )
    }

    /// 业务作用：完全处于文档注释、heredoc 或数据段的行只发布着色资格，不发布结构词。
    /// 参数说明:
    /// - style: 当前物理正文的原生样式。
    /// - ending: 原始行结束字节的样式。
    /// 返回：保留隔离状态且没有代码词元的完整物理行。
    private static func opaqueRow(_ style: RubyHighlightStyle, ending: RubyHighlightStyle?) -> Row {
        Row(
            tokens: [],
            beginsInLiteral: true,
            holdsLiteral: true,
            commentStart: nil,
            entirelyOpaque: true,
            opaqueStyle: style,
            endingStyle: ending
        )
    }

    /// 业务作用：Ruby 文档注释只有在真实行首和合法后继处改变跨行状态。
    /// 参数说明:
    /// - marker: 已知 Ruby 行首指令。
    /// - bytes: 当前物理行的原字节。
    /// 返回：完整行首指令有实际词尾边界时为真。
    private static func directive(_ marker: String, in bytes: [UInt8]) -> Bool {
        let size = marker.utf8.count
        return bytes.starts(with: marker.utf8) && (bytes.count == size || blank(bytes[size]))
    }

    /// 业务作用：同源名称边界保护关键词与变量，非 ASCII 字节在词内保持原样。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：可能开始 Ruby 名称时为真。
    static func nameStart(_ byte: UInt8) -> Bool {
        byte >= 128 || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：已完整识别普通词和数据分隔符时保留数字后缀。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：可属于名称或数据分隔符时为真。
    static func namePart(_ byte: UInt8) -> Bool {
        nameStart(byte) || (48...57).contains(byte)
    }

    /// 业务作用：水平原字节空白用于词元和指令边界，正文的其它控制符保留。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：空格或水平 Tab 时为真。
    static func blank(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 32
    }

    /// 业务作用：字符字面和特殊变量跳过完整源标量，不能留下半个 UTF-8 字节作为词端点。
    /// 参数说明:
    /// - byte: 由正文树确认的标量首字节。
    /// 返回：当个合法原标量的 UTF-8 宽度。
    private static func scalarLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0...127: 1
        case 194...223: 2
        case 224...239: 3
        case 240...244: 4
        default: 1
        }
    }

    /// 业务作用：引入表达式的实际关键字为紧随的正则和百分号字面提供上下文。
    /// 参数说明:
    /// - word: 已确认的真实 Ruby 关键字。
    /// 返回：后面允许开始表达式时为真。
    private static func prefixesExpression(_ word: Word?) -> Bool {
        switch word {
        case .conditional, .unless, .elsif, .when, .pattern, .choice, .looping, .until, .iteration, .then,
            .fallback, .rescue, .and, .or, .not, .returning, .yielding:
            true
        default:
            false
        }
    }
}
