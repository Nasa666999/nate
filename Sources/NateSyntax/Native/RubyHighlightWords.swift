import NateCore

struct RubyHighlightWords {
    private static let postfixed: Set<String> = ["if", "unless", "while", "until", "rescue"]
    private var declaration: RubyHighlightStyle?
    private var expectsValue = true
    private var qualified = false
    private var continuesMethodName = false

    /// 业务作用：利用真实代码词元在原生主题中区分数字、可命名作用域、变量、符号及后缀关键词。
    /// 参数说明:
    /// - row: 结构词法已经核对的完整物理行。
    /// - bytes: 同一物理行的完整原始范围，包含实际结束字节。
    /// - keywords: 当前 Ruby 语言的有效原始词表。
    /// - budget: 同一高亮调用的计算和截止额度。
    /// 返回：按原字节顺序给出完整行样式；缩进与折叠使用原独立结构证据。
    mutating func styles(
        for row: RubyIndentationLexer.Row,
        bytes: [UInt8],
        keywords: Set<String>,
        budget: inout ANSILexingBudget
    ) throws -> [RubyHighlightStyle] {
        let bodyEnd =
            bytes.last == 10
            ? bytes.count - (bytes.count > 1 && bytes[bytes.count - 2] == 13 ? 2 : 1)
            : bytes.count - (bytes.last == 13 ? 1 : 0)
        var styles = Array(repeating: row.opaqueStyle ?? .whitespace, count: bytes.count)
        if let close = row.heredocEnd {
            apply(.heredocDelimiter, to: close..<bodyEnd, in: &styles)
        }
        apply(row.endingStyle ?? .whitespace, to: bodyEnd..<bytes.count, in: &styles)
        if row.entirelyOpaque {
            return styles
        }
        var previous: RubyIndentationLexer.Token?
        for token in row.tokens {
            try budget.consume()
            let start = token.span.lower
            let end = token.span.upper
            let raw = bytes[start..<end]
            let style: RubyHighlightStyle
            if let literal = token.highlightStyle {
                style = literal
                if literal == .heredocDelimiter {
                    apply(.operation, to: start..<(start + 2), in: &styles)
                    apply(style, to: (start + 2)..<end, in: &styles)
                    expectsValue = false
                    qualified = false
                    previous = token
                    continue
                }
                declaration = nil
                expectsValue = false
                qualified = false
            }
            else {
                switch token.kind {
                case .symbol(let byte):
                    style = operation(byte, at: start, source: bytes, previous: previous, styles: &styles)
                case .assignment:
                    style = operation(61, at: start, source: bytes, previous: previous, styles: &styles)
                case .word, .operand:
                    style = word(raw, from: bytes, keywords: keywords)
                }
            }
            if style == .identifier, raw.last == 58, raw.count > 1 {
                if end == bodyEnd || RubyIndentationLexer.blank(bytes[end]) {
                    apply(.symbol, to: start..<end, in: &styles)
                }
                else {
                    apply(style, to: start..<(end - 1), in: &styles)
                    styles[end - 1] = .operation
                }
                expectsValue = true
            }
            else {
                apply(style, to: start..<end, in: &styles)
            }
            previous = token
        }
        if let start = row.commentStart {
            apply(.lineComment, to: start..<bodyEnd, in: &styles)
        }
        return styles
    }

    /// 业务作用：优先确认真实声明名和接收者，成员关键字、标签和符号保留各自身份。
    /// 参数说明:
    /// - raw: 当前词元的真实原字节范围。
    /// - bytes: 用于确认相邻接收者和符号的同源物理行。
    /// - keywords: 当前完整原词表。
    /// 返回：当前词元的原生样式及下一词元的实际声明资格。
    private mutating func word(
        _ raw: ArraySlice<UInt8>,
        from bytes: [UInt8],
        keywords: Set<String>
    ) -> RubyHighlightStyle {
        let end = raw.endIndex
        let value = raw.count <= 1024 ? String(decoding: raw, as: UTF8.self) : ""
        let isQualified = qualified
        qualified = false
        defer {
            expectsValue = false
        }
        if let first = raw.first {
            if (48...57).contains(first) {
                declaration = nil
                return .number
            }
            if first == 36 {
                declaration = nil
                return .global
            }
            if first == 64 {
                declaration = nil
                return raw.dropFirst().first == 64 ? .classVariable : .instance
            }
        }
        if let pending = declaration {
            declaration = nil
            if pending == .methodName, end < bytes.count,
                bytes[end] == 46 || bytes[end] == 58 && end + 1 < bytes.count && bytes[end + 1] == 58
            {
                continuesMethodName = true
                return value == "self" ? .demotedKeyword : .identifier
            }
            return pending
        }
        guard !isQualified, keywords.contains(value) else {
            return .identifier
        }
        switch value {
        case "class": declaration = .className
        case "def": declaration = .methodName
        case "module": declaration = .moduleName
        default: break
        }
        return Self.postfixed.contains(value) && !expectsValue ? .demotedKeyword : .keyword
    }

    /// 业务作用：符号名称、变量及操作符作为完整字面消费，冒号或分隔符不能制造代码块。
    /// 参数说明:
    /// - bytes: 当前物理行的不含结束符的完整原字节。
    /// - colon: 已确认的真实冒号位置。
    /// - check: 当前词法任务的共同继续资格。
    /// 返回：完整符号端点；名称空间、带引号的字面及独立冒号交给各自规则。
    static func symbolEnd(in bytes: [UInt8], at colon: Int, check: () throws -> Void) throws -> Int? {
        let start = colon + 1
        guard start < bytes.count, bytes[start] != 58, colon == 0 || bytes[colon - 1] != 58 else {
            return nil
        }
        let first = bytes[start]
        let next = start + 1 < bytes.count ? bytes[start + 1] : 0
        var index = start
        if first == 64 || first == 36 {
            index += 1
            if first == 64 && next == 64 || first == 36 && next == 45 {
                index += 1
            }
            guard index < bytes.count else {
                return nil
            }
            if first == 36, !RubyIndentationLexer.namePart(bytes[index]) {
                return RubyIndentationLexer.blank(bytes[index]) ? nil : index + 1
            }
        }
        if index < bytes.count, RubyIndentationLexer.namePart(bytes[index]) {
            while index < bytes.count, RubyIndentationLexer.namePart(bytes[index]) {
                if index & 255 == 0 {
                    try check()
                }
                index += 1
            }
            if index < bytes.count {
                let following = index + 1 < bytes.count ? bytes[index + 1] : 0
                if [33, 63].contains(bytes[index]) && following != 61
                    || bytes[index] == 61 && ![61, 62, 126].contains(following)
                {
                    index += 1
                }
            }
            return index
        }
        guard index == start else {
            return nil
        }
        for candidate in ["[]=", "<=>", "[]", "**", "!=", "!~", "<<", "<="] {
            if bytes[start...].starts(with: candidate.utf8) {
                return start + candidate.utf8.count
            }
        }
        return [33, 37, 38, 42, 43, 45, 47, 60, 61, 62, 94, 124, 126].contains(first) ? start + 1 : nil
    }

    /// 业务作用：标点保持真实接收者、输入值和数字上下文，范围点号不会被小数合并。
    /// 参数说明:
    /// - byte: 当前位置实际操作符字节。
    /// - index: 该字节在原物理行中的位置。
    /// - source: 当前物理行用于检查相邻数字、范围及接收者。
    /// - previous: 扫描顺序中的前一个已确认词元。
    /// - styles: 已建立的行前缀样式。
    /// 返回：保留原始作用的操作符或小数点类别。
    private mutating func operation(
        _ byte: UInt8,
        at index: Int,
        source: [UInt8],
        previous: RubyIndentationLexer.Token?,
        styles: inout [RubyHighlightStyle]
    ) -> RubyHighlightStyle {
        if continuesMethodName, byte == 46 || byte == 58 {
            if byte == 46 || (index > 0 && source[index - 1] == 58) {
                declaration = .methodName
                continuesMethodName = false
            }
        }
        else if byte != 58 {
            declaration = nil
        }
        qualified = byte == 46 || byte == 58
        expectsValue = ![41, 93, 125].contains(byte)
        if byte == 46, index > 0, index + 1 < source.count,
            previous?.span.upper == index, styles[index - 1] == .number, (48...57).contains(source[index + 1])
        {
            return .number
        }
        return .operation
    }

    /// 业务作用：按已确认原字节范围写入当前物理行的着色副本，不触碰正文。
    /// 参数说明:
    /// - style: 已确认的原生类别。
    /// - range: 当前物理行内的完整范围。
    /// - values: 同一物理行的原始顺序样式。
    /// 返回：指定范围采用同一类别。
    private func apply(
        _ style: RubyHighlightStyle,
        to range: Range<Int>,
        in values: inout [RubyHighlightStyle]
    ) {
        for index in range {
            values[index] = style
        }
    }
}
