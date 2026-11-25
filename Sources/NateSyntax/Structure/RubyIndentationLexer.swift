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
        var continuingLiteralStyle: RubyHighlightStyle? = nil
        var heredocOpening: Int? = nil
        var heredocCount = 0
        var heredocEnd: Int? = nil
        var interpolation: RubyInterpolationHighlights? = nil
    }

    private var literal = RubyLiteralState()
    private var heredocs: [RubyHeredoc] = []
    private var documentation = false
    private var dataSection = false
    private var literalStyle: RubyHighlightStyle? = nil

    /// 业务作用：逐行保持 Ruby 真实字面、文档注释和数据边界，只向结构缩进交付可消费的代码词元。
    /// 参数说明:
    /// - bytes: 同一固定正文中当前物理行的完整原字节，排除结束符。
    /// - highlightInterpolations: 当前调用需要独立的插值呈现时为真。
    /// - check: 全部目标、词法及最终提交共用的截止和继续资格。
    /// 返回：按真实相对偏移升序的词元以及仍处于隔离状态的边界；超量或取消拒绝整批。
    mutating func row(
        _ bytes: [UInt8],
        highlightInterpolations: Bool = false,
        check: () throws -> Void
    ) throws -> Row {
        try check()
        if let document = heredocs.first {
            if let close = document.closingOffset(in: bytes) {
                heredocs.removeFirst()
                var row = Self.opaqueRow(
                    document.style,
                    ending: heredocs.first?.continuationStyle ?? literal.liveStyle
                )
                row.heredocEnd = close
                return row
            }
            var embedded: [RubyHeredoc] = []
            let (interpolation, ending) = try heredocs[0].scanBody(
                bytes,
                highlight: highlightInterpolations,
                embedded: &embedded,
                check: check
            )
            var row = Self.opaqueRow(document.style, ending: embedded.first?.style ?? ending)
            row.interpolation = interpolation
            if let opening = embedded.first {
                // 子正文在挂起的父正文之前消费，父分隔符不能在该段内结束外层字面或恢复结构权限。
                guard embedded.count <= Self.maximumHeredocs - heredocs.count else {
                    throw NateError.message("Ruby 同时等待的 heredoc 超过 256 个。")
                }
                row.heredocOpening = opening.openingOffset
                row.heredocCount = embedded.count
                heredocs.insert(contentsOf: embedded, at: 0)
            }
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
        var highlights =
            highlightInterpolations
            ? RubyInterpolationHighlights(initialDepth: literal.interpolationDepth) : nil
        var tokens: [Token] = []
        var index = 0
        var commentStart: Int?
        var code = RubyCodePosition(expectsOperand: !beginsInLiteral)
        if beginsInLiteral {
            try literal.advance(
                in: bytes,
                from: &index,
                highlights: &highlights,
                heredocs: &heredocs,
                check: check
            )
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
            let acceptsLiteral = code.acceptsLiteral(in: bytes, at: index)
            if let token = try code.takeStandaloneLiteral(in: bytes, from: &index, check: check) {
                tokens.append(token)
                continue
            }
            if acceptsLiteral,
                let (document, after) = try RubyHeredoc.opening(in: bytes, at: index, check: check)
            {
                try Self.appendHeredoc(document, to: &heredocs)
                index = after
                tokens.append(
                    Token(kind: .operand, span: ByteRange(start, index), highlightStyle: .heredocDelimiter)
                )
                code.consumeValue()
                continue
            }
            if let (delimiter, after) = RubyLiteralState.opener(in: bytes, at: index, pattern: acceptsLiteral)
            {
                literal.begin(delimiter)
                index = after
                let style = delimiter.style
                try literal.advance(
                    in: bytes,
                    from: &index,
                    highlights: &highlights,
                    heredocs: &heredocs,
                    check: check
                )
                literalStyle = literal.isOpen ? style : nil
                tokens.append(Token(kind: .operand, span: ByteRange(start, index), highlightStyle: style))
                code.consumeValue()
                continue
            }
            tokens.append(try code.take(in: bytes, from: &index, check: check))
        }
        return Row(
            tokens: tokens,
            beginsInLiteral: beginsInLiteral,
            holdsLiteral: literal.isOpen,
            commentStart: commentStart,
            entirelyOpaque: false,
            endingStyle: heredocs.first?.style ?? literal.liveStyle,
            continuingLiteralStyle: literalStyle,
            heredocOpening: heredocs.first?.openingOffset,
            heredocCount: heredocs.count,
            interpolation: highlights
        )
    }

    private static let maximumHeredocs = 256

    /// 业务作用：顶层代码与插值声明共用当前物理行队列，多个正文依次沿原声明边界读取。
    /// 参数说明:
    /// - document: 当前语境完整确认的 heredoc 声明。
    /// - queue: 该物理行已有声明的实际原始顺序。
    /// 返回：预算内追加；超量停止整行，避免把未登记正文当作代码。
    static func appendHeredoc(_ document: RubyHeredoc, to queue: inout [RubyHeredoc]) throws {
        guard queue.count < maximumHeredocs else {
            throw NateError.message("Ruby 同行 heredoc 声明超过 256 个。")
        }
        queue.append(document)
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
    static func scalarLength(_ byte: UInt8) -> Int {
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
    static func prefixesExpression(_ word: Word?) -> Bool {
        switch word {
        case .conditional, .unless, .elsif, .when, .pattern, .choice, .looping, .until, .iteration, .then,
            .fallback, .rescue, .and, .or, .not, .returning, .yielding:
            true
        default:
            false
        }
    }
}
