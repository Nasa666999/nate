import Foundation
import NateCore

struct BashHighlightScanner {
    let bytes: [UInt8]
    let keywords: Set<String>
    var budget: ANSILexingBudget
    var state: BashHighlightState
    private(set) var styles: [UInt8]

    private static let controlWords: Set<String> = [
        "if", "elif", "fi", "while", "until", "else", "then", "do", "done", "esac", "eval",
    ]
    private static let iteratorWords: Set<String> = ["for", "case", "select"]
    private static let binaryTests: Set<String> = ["eq", "ge", "gt", "le", "lt", "ne", "ef", "nt", "ot"]
    private static let unaryTests = Set("rwxoRWXOezsfdlpSbctugkTBMACahGLNn".utf8)
    private static let meta = Set("|&;()<> \t\r\n\0".utf8)
    private static let operators = Set("^&%()-+=|{}[]:;>,*/<?!.~@".utf8)
    private static let separators = Set("|&;(){}".utf8)
    private static let namedParameters = Set("*@#?-$!".utf8)

    /// 业务作用：以完整原物理行及上游连续状态构造 Bash 原字节样式。
    /// 参数说明:
    /// - bytes: 当前行原字节，可包含真实行尾。
    /// - keywords: 当前语言资源的完整 Bash 命令词表。
    /// - budget: 本行原字节、引用传播和样式构造共用的预算。
    /// - state: 上一个已完成物理行的词法证据。
    /// 返回：尚未发布的独立扫描器。
    init(bytes: [UInt8], keywords: Set<String>, budget: ANSILexingBudget, state: BashHighlightState) {
        self.bytes = bytes
        self.keywords = keywords
        self.budget = budget
        self.state = state
        styles = Array(repeating: 0, count: bytes.count)
    }

    /// 业务作用：完整物理行只在引用、字面正文、数值和命令位置均判定后提供原始样式。
    /// 参数说明: 无。
    /// 返回：按原字节对齐的样式及连续下一行状态；容量耗尽或取消时抛错。
    mutating func scan() throws -> [UInt8] {
        try budget.check()
        var end = bytes.count
        if bytes.last == 10 {
            end -= 1
        }
        if end > 0 && bytes[end - 1] == 13 {
            end -= 1
        }
        if let here = state.here {
            let body = bytes[..<end]
            let candidate = here.stripsTabs ? body.drop(while: { $0 == 9 }) : body
            if candidate.elementsEqual(here.delimiter) {
                try paint(0..<candidate.startIndex, .hereText)
                try paint(candidate.startIndex..<end, .hereDelimiter)
                state.here = nil
                state.command = .start
            }
            else {
                try paint(0..<bytes.count, .hereText)
            }
            return styles
        }
        if state.quotes.isEmpty && !state.continued
            && state.command != .arithmetic && state.command != .doubleBracket
        {
            state.command = .start
        }
        state.continued = false
        var cursor = 0
        while cursor < end {
            try budget.consume()
            if !state.quotes.isEmpty {
                try quote(at: &cursor, limit: end)
                continue
            }
            let start = cursor
            let byte = bytes[cursor]
            let previous = cursor == 0 ? 0 : bytes[cursor - 1]
            let next = cursor + 1 < end ? bytes[cursor + 1] : 0
            let arithmetic = state.command == .arithmetic
            switch byte {
            case 9, 32:
                cursor += 1
            case 35 where cursor == 0 || Self.meta.contains(previous):
                try paint(cursor..<end, .comment)
                cursor = end
            case 34, 39, 96:
                let scope: BashHighlightQuote = byte == 34 ? .string : byte == 39 ? .literal : .backticks
                try state.push(scope)
                try paint(cursor..<(cursor + 1), scope.style)
                cursor += 1
                beginArguments()
            case 36:
                try variable(at: &cursor, limit: end)
            case 92:
                cursor += 1
                if cursor == end {
                    state.continued = bytes.count > end
                    try paint(
                        start..<cursor,
                        state.continued ? .punctuation : .identifier
                    )
                }
                else {
                    cursor = scalarEnd(from: cursor, limit: end)
                    while cursor < end && BashHighlightNumbers.wordByte(bytes[cursor], arithmetic: arithmetic)
                    {
                        try budget.consume()
                        cursor += 1
                    }
                    try paint(start..<cursor, .identifier)
                    beginArguments()
                }
            case 48...57:
                let number = try BashHighlightNumbers.scan(
                    bytes[..<end],
                    from: cursor,
                    arithmetic: arithmetic,
                    budget: &budget
                )
                cursor = number.end
                try paint(start..<cursor, number.style)
                beginArguments()
            case 60 where !arithmetic && next == 60:
                try hereDocument(at: &cursor, limit: end)
                beginArguments()
            default:
                if BashHighlightNumbers.wordStart(byte) || byte == 35
                    || byte == 45 && !arithmetic
                        && !BashHighlightNumbers.decimal(next) && previous != 126
                {
                    try word(at: &cursor, limit: end)
                }
                else if Self.operators.contains(byte) {
                    try operation(at: &cursor, limit: end)
                }
                else {
                    cursor = scalarEnd(from: cursor, limit: end)
                    if byte != 0 {
                        beginArguments()
                    }
                }
            }
        }
        if let scope = state.quotes.first {
            try paint(end..<bytes.count, scope.style)
        }
        else if state.here != nil {
            try paint(end..<bytes.count, .hereText)
        }
        try budget.check()
        return styles
    }

    /// 业务作用：从当前命令位置识别实际关键字、测试选项及普通参数。
    /// 参数说明:
    /// - cursor: 本次原始词起点。
    /// - limit: 本物理行正文的结束位置。
    /// 返回：词的全部原字节有明确类别后推进位置。
    private mutating func word(at cursor: inout Int, limit: Int) throws {
        let start = cursor
        // 错误进制后的井号仍属于未完成词，后继数字不能重新取得算术数值类别。
        let followsBadRadix =
            bytes[start] == 35 && start > 0 && styles[start - 1] == BashHighlightStyle.error.rawValue
        let arithmetic = state.command == .arithmetic && !followsBadRadix
        cursor += 1
        while cursor < limit {
            try budget.consume()
            let byte = bytes[cursor]
            guard BashHighlightNumbers.wordByte(byte, arithmetic: arithmetic) || byte == 35 && !arithmetic
            else {
                break
            }
            if cursor + 1 < limit
                && (byte == 43 && bytes[cursor + 1] == 61 || byte == 46 && bytes[cursor + 1] == 46)
            {
                break
            }
            cursor += 1
        }
        let boundary =
            cursor == limit || Self.meta.contains(bytes[cursor]) || Self.separators.contains(bytes[cursor])
        let value = cursor - start < 500 ? String(decoding: bytes[start..<cursor], as: UTF8.self) : ""
        var style = BashHighlightStyle.identifier
        if boundary {
            switch state.command {
            case .iterator:
                if value == "in" || value == "do" {
                    style = .keyword
                    state.command = value == "do" ? .start : .arguments
                }
            case .start:
                if Self.iteratorWords.contains(value) {
                    style = .keyword
                    state.command = .iterator
                }
                else if Self.controlWords.contains(value) {
                    style = .keyword
                }
                else if value == "test" {
                    style = .keyword
                    state.command = .test
                }
                else {
                    style = keywords.contains(value) && !value.hasPrefix("-") ? .keyword : .identifier
                    state.command = .arguments
                }
            case .test, .singleBracket, .doubleBracket:
                if value.hasPrefix("-") {
                    let name = value.dropFirst()
                    if name.utf8.count == 1 && name.utf8.first.map(Self.unaryTests.contains) == true
                        || Self.binaryTests.contains(String(name))
                    {
                        style = .keyword
                    }
                }
            default:
                break
            }
        }
        else {
            beginArguments()
        }
        try paint(start..<cursor, style)
    }

    /// 业务作用：区分算术、测试括号和真实命令分隔的 Bash 操作符。
    /// 参数说明:
    /// - cursor: 当前原生操作符起点。
    /// - limit: 本物理行正文的结束位置。
    /// 返回：分隔符可以开启新的关键词上下文；其余保持本语法范围。
    private mutating func operation(at cursor: inout Int, limit: Int) throws {
        let start = cursor
        let byte = bytes[cursor]
        let next = cursor + 1 < limit ? bytes[cursor + 1] : 0
        cursor += 1
        if state.command == .arithmetic {
            if byte == state.arithmeticCloser {
                state.arithmeticDepth -= 1
                if state.arithmeticDepth <= 0 {
                    state.command = .arguments
                }
            }
            else if byte == (state.arithmeticCloser == 93 ? 91 : 40) {
                state.arithmeticDepth += 1
            }
        }
        else if byte == 40 && next == 40 {
            state.command = .arithmetic
            state.arithmeticDepth = 2
            state.arithmeticCloser = 41
            cursor += 1
        }
        else if byte == 91 && (state.command == .start || state.command == .arguments) {
            if next == 91, cursor + 1 < limit, Self.meta.contains(bytes[cursor + 1]) {
                state.command = .doubleBracket
                cursor += 1
            }
            else if next == 9 || next == 32 {
                state.command = .singleBracket
            }
        }
        else if byte == 93 && state.command == .doubleBracket && next == 93 {
            state.command = .arguments
            cursor += 1
        }
        else if byte == 93 && state.command == .singleBracket {
            state.command = .arguments
        }
        else if Self.separators.contains(byte) && state.command != .doubleBracket {
            state.command = .start
        }
        else {
            beginArguments()
        }
        try paint(start..<cursor, .punctuation)
    }

    /// 业务作用：处理独立变量和嵌套引用入口，裸美元符没有变量身份。
    /// 参数说明:
    /// - cursor: 确切美元符字节起点。
    /// - limit: 当前行合法正文末端。
    /// 返回：只使用完整前缀开启实际变量、引用或算术表达式。
    private mutating func variable(at cursor: inout Int, limit: Int) throws {
        let start = cursor
        cursor += 1
        guard cursor < limit else {
            return
        }
        let byte = bytes[cursor]
        switch byte {
        case 39, 34, 123:
            let scope: BashHighlightQuote = byte == 39 ? .escapedLiteral : byte == 34 ? .string : .parameter
            try state.push(scope)
            cursor += 1
            try paint(start..<cursor, scope.style)
        case 40, 91:
            cursor += 1
            if byte == 91 || cursor < limit && bytes[cursor] == 40 {
                state.command = .arithmetic
                state.arithmeticCloser = byte == 91 ? 93 : 41
                state.arithmeticDepth = byte == 91 ? 1 : 2
                if byte == 40 {
                    cursor += 1
                }
                try paint(start..<cursor, .punctuation)
            }
            else {
                try state.push(.command)
                try paint(start..<cursor, .command)
            }
        default:
            if Self.namedParameters.contains(byte) {
                cursor += 1
            }
            else {
                while cursor < limit
                    && (BashHighlightNumbers.wordStart(bytes[cursor])
                        || BashHighlightNumbers.decimal(bytes[cursor]))
                {
                    try budget.consume()
                    cursor += 1
                }
            }
            if cursor > start + 1 {
                try paint(start..<cursor, .scalar)
            }
        }
        beginArguments()
    }

    /// 业务作用：传播实际引号、参数及命令替换，外层引用的颜色覆盖其内部原字节。
    /// 参数说明:
    /// - cursor: 当前引用中的原字节位置。
    /// - limit: 当前行实际原文末端。
    /// 返回：消费经过验证的关闭、嵌套或转义，未匹配上下文留给后继行。
    private mutating func quote(at cursor: inout Int, limit: Int) throws {
        guard let scope = state.quotes.last, let style = state.quotes.first?.style else {
            return
        }
        let start = cursor
        let byte = bytes[cursor]
        let next = cursor + 1 < limit ? bytes[cursor + 1] : 0
        cursor += 1
        if byte == 92 && scope != .literal {
            cursor = scalarEnd(from: cursor, limit: limit)
        }
        else if scope == .literal || scope == .escapedLiteral {
            if byte == 39 {
                state.quotes.removeLast()
            }
        }
        else if scope == .string && byte == 34 || scope == .backticks && byte == 96
            || scope == .command && byte == 41 || scope == .parameter && byte == 125
        {
            state.quotes.removeLast()
        }
        else if byte == 36 && (next == 40 || next == 123) {
            try state.push(next == 40 ? .command : .parameter)
            cursor += 1
        }
        else if byte == 96 {
            try state.push(.backticks)
        }
        else if scope == .command || scope == .parameter {
            if byte == 34 || byte == 39 {
                try state.push(byte == 34 ? .string : .literal)
            }
            else if scope == .command && byte == 40 || scope == .parameter && byte == 123 {
                try state.push(scope)
            }
        }
        try paint(start..<cursor, style)
    }

    /// 业务作用：登记普通 here-document 的原始分隔符并区分独立 here-string。
    /// 参数说明:
    /// - cursor: 已确认的双小于号起点。
    /// - limit: 当前物理行正文结束位置。
    /// 返回：真实分隔符样式及后续正文状态；缺少明确分隔符时维持普通操作符边界。
    private mutating func hereDocument(at cursor: inout Int, limit: Int) throws {
        let start = cursor
        cursor += 2
        if cursor < limit && bytes[cursor] == 60 {
            cursor += 1
            try paint(start..<cursor, .hereDelimiter)
            return
        }
        let stripsTabs = cursor < limit && bytes[cursor] == 45
        if stripsTabs {
            cursor += 1
        }
        while cursor < limit && (bytes[cursor] == 9 || bytes[cursor] == 32) {
            try budget.consume()
            cursor += 1
        }
        let delimiterStart = cursor
        var quote: UInt8?
        while cursor < limit {
            try budget.consume()
            let byte = bytes[cursor]
            if quote == byte {
                quote = nil
            }
            else if quote == nil && (byte == 34 || byte == 39) {
                quote = byte
            }
            else if byte == 92 && quote != 39 && cursor + 1 < limit {
                cursor += 1
            }
            else if quote == nil && Self.meta.contains(byte) {
                break
            }
            cursor += 1
        }
        if cursor > delimiterStart, quote == nil,
            let delimiter = BashIndentationLexer.delimiter(bytes[delimiterStart..<cursor])
        {
            state.here = BashHighlightDocument(delimiter: delimiter, stripsTabs: stripsTabs)
        }
        try paint(start..<cursor, .hereDelimiter)
    }

    /// 业务作用：普通命令的首个词或值结束保留字起始资格。
    /// 参数说明: 无。
    /// 返回：独立测试、算术和循环头仍保留自己的语法状态。
    private mutating func beginArguments() {
        if state.command == .start {
            state.command = .arguments
        }
    }

    /// 业务作用：转义和未着色内容仍按完整 Unicode 标量移动，不能拆分真实显示区域。
    /// 参数说明:
    /// - start: 已知标量的首字节。
    /// - limit: 此行正文边界。
    /// 返回：行内完整标量之后的位置。
    private func scalarEnd(from start: Int, limit: Int) -> Int {
        guard start < limit else {
            return start
        }
        var end = start + 1
        while end < limit && bytes[end] & 192 == 128 {
            end += 1
        }
        return end
    }

    /// 业务作用：所有实际发布的原字节样式都计入同一处理预算。
    /// 参数说明:
    /// - range: 已核对属于本行的样式范围。
    /// - style: 真实 Bash 原生样式。
    /// 返回：有足够处理资格时记录整段，否则丢弃本次扫描。
    private mutating func paint(_ range: Range<Int>, _ style: BashHighlightStyle) throws {
        for index in range {
            try budget.consume()
            styles[index] = style.rawValue
        }
    }
}
