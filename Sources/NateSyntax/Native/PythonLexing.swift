import Foundation
import NateCore

struct PythonLiteral: Sendable, Equatable {
    let quote: UInt8
    let triple: Bool
    let formatted: Bool
    var style: Int {
        if triple {
            return formatted ? (quote == 34 ? 19 : 18) : (quote == 34 ? 7 : 6)
        }
        return formatted ? (quote == 34 ? 16 : 17) : (quote == 34 ? 3 : 4)
    }
}

struct PythonExpression: Sendable, Equatable {
    let literal: PythonLiteral
    var depth: Int
}

struct PythonLexicalState: Sendable, Equatable {
    var literal: PythonLiteral?
    var expressions: [PythonExpression] = []
}

enum PythonLexing {
    /// 业务作用：在完整物理行之间传播 Python 字符串和插值表达式状态，字面内容不冒充可折叠代码。
    /// 参数说明:
    /// - text: 当前物理行，最后一行可没有换行。
    /// - base: 该行在快照内的 UTF-8 起点。
    /// - keywords: 当前资源的精确关键字集合。
    /// - state: 当前快照独立维护的词法状态和容量说明。
    /// 返回：原字节范围内的呈现片段，超出单行或嵌套预算时记录原因并拒绝后续样式。
    static func highlight(
        _ text: String,
        base: Int,
        keywords: Set<String>,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        // 已失去完整状态的流程不能恢复为中性代码；调用方必须舍弃本次未发布的解析结果。
        guard state.diagnostic == nil else {
            return []
        }
        guard text.utf8.count <= 1_048_576 else {
            state.diagnostic = "Python 高亮暂停：单行超过 1 MB。"
            return []
        }
        let bytes = Array(text.utf8)
        var output: [SyntaxToken] = []
        var exceeded = false
        var cursor = 0
        var literalStart: Int?
        /// 业务作用：保留 Python 原词法分类，外观相同的不同字符串区域仍具有独立结构身份。
        /// 参数说明:
        /// - start: 当前片段的行内字节起点。
        /// - end: 当前片段的行内结束边界。
        /// - style: Python 公开词法样式编号。
        /// 返回：非空片段加入本次呈现，不修改正文或历史。
        func emit(_ start: Int, _ end: Int, style: Int) {
            guard end > start else {
                return
            }
            guard output.count < 65_536 else {
                exceeded = true
                return
            }
            let kind: SyntaxKind
            switch style {
            case 1, 12: kind = .comment
            case 2: kind = .number
            case 3, 4, 6, 7, 13, 16, 17, 18, 19: kind = .string
            case 5, 8, 9, 14, 15: kind = .keyword
            case 10: kind = .punctuation
            default: kind = .text
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(base + start, base + end),
                    kind: kind,
                    lexicalStyle: "python:\(style)"
                )
            )
        }
        while cursor < bytes.count && !exceeded {
            if let literal = state.python.literal {
                let start = literalStart ?? cursor
                literalStart = nil
                var style = literal.style
                var continued = false
                while cursor < bytes.count {
                    let byte = bytes[cursor]
                    if byte == 92 {
                        if literal.formatted && cursor + 1 < bytes.count && bytes[cursor + 1] == 123 {
                            // 反斜杠不转义插值起始括号，下一步仍须进入表达式区域。
                            cursor += 1
                        }
                        else if cursor + 1 < bytes.count && [10, 13].contains(bytes[cursor + 1]) {
                            cursor += 2
                            if bytes[cursor - 1] == 13, cursor < bytes.count, bytes[cursor] == 10 {
                                cursor += 1
                            }
                            continued = true
                        }
                        else {
                            cursor = min(bytes.count, cursor + 2)
                        }
                    }
                    else if matchesQuote(bytes, at: cursor, literal: literal) {
                        cursor += literal.triple ? 3 : 1
                        state.python.literal = nil
                        break
                    }
                    else if literal.formatted && byte == 123 {
                        if cursor + 1 < bytes.count && bytes[cursor + 1] == 123 {
                            cursor += 2
                            continue
                        }
                        // 插值状态保存外层字符串；超过有界栈后不能继续猜测代码与字面区域。
                        guard state.python.expressions.count < 64 else {
                            state.diagnostic = "Python 高亮暂停：插值嵌套超过 64 层。"
                            return []
                        }
                        cursor += 1
                        state.python.expressions.append(
                            PythonExpression(
                                literal: literal,
                                depth: 0
                            )
                        )
                        state.python.literal = nil
                        break
                    }
                    else if !literal.triple && [10, 13].contains(byte) {
                        style = 13
                        state.python.literal = nil
                        if byte == 13, cursor + 1 < bytes.count, bytes[cursor + 1] == 10 {
                            cursor += 1
                        }
                        cursor += 1
                        break
                    }
                    else {
                        cursor += 1
                    }
                }
                if state.python.literal != nil && !literal.triple && !continued {
                    state.python.literal = nil
                    style = 13
                }
                emit(start, cursor, style: style)
                continue
            }
            let start = cursor
            let byte = bytes[cursor]
            if let expression = state.python.expressions.last {
                let conversion = byte == 33 && (cursor + 1 == bytes.count || bytes[cursor + 1] != 61)
                if expression.depth == 0 && (byte == 125 || byte == 58 || conversion) {
                    // 最外层格式分隔符属于原字符串，字典和括号内部的同类字符仍属于表达式。
                    state.python.literal = state.python.expressions.removeLast().literal
                    continue
                }
                if [40, 91, 123].contains(byte) {
                    state.python.expressions[state.python.expressions.count - 1].depth += 1
                }
                else if [41, 93, 125].contains(byte) {
                    state.python.expressions[state.python.expressions.count - 1].depth = max(
                        0,
                        expression.depth - 1
                    )
                }
            }
            if let opening = literalOpening(bytes, at: cursor) {
                state.python.literal = opening.literal
                literalStart = cursor
                cursor = opening.end
            }
            else if byte == 35 {
                while cursor < bytes.count && ![10, 13].contains(bytes[cursor]) {
                    cursor += 1
                }
                emit(start, cursor, style: start + 1 < bytes.count && bytes[start + 1] == 35 ? 12 : 1)
            }
            else if (48...57).contains(byte)
                || (byte == 46 && cursor + 1 < bytes.count && (48...57).contains(bytes[cursor + 1]))
            {
                cursor = numberEnd(bytes, at: cursor)
                emit(start, cursor, style: 2)
            }
            else if SyntaxEngine.isWord(byte) {
                cursor += 1
                while cursor < bytes.count
                    && (SyntaxEngine.isWord(bytes[cursor]) || (48...57).contains(bytes[cursor]))
                {
                    cursor += 1
                }
                let word = String(decoding: bytes[start..<cursor], as: UTF8.self)
                emit(start, cursor, style: keywords.contains(word) ? 5 : 11)
            }
            else {
                cursor += 1
                if "+-*/%&|^~<>=()[]{}:.,;@`".utf8.contains(byte) {
                    emit(start, cursor, style: 10)
                }
            }
        }
        if let start = literalStart, let literal = state.python.literal {
            emit(start, cursor, style: literal.triple ? literal.style : 13)
            if !literal.triple {
                state.python.literal = nil
            }
        }
        if exceeded {
            state.diagnostic = "Python 高亮暂停：单行词法片段超过 65536 个。"
            return []
        }
        return output
    }

    /// 业务作用：识别单引号、三引号及允许的字面前缀，不把标识符内部字母拆成字符串前缀。
    /// 参数说明:
    /// - bytes: 当前完整行的 UTF-8 字节。
    /// - offset: 当前尚未消费的字节位置。
    /// 返回：完整起始标记后的边界和字符串类型，没有匹配时为空。
    private static func literalOpening(_ bytes: [UInt8], at offset: Int) -> (
        literal: PythonLiteral, end: Int
    )? {
        var quote = offset
        if ![34, 39].contains(bytes[quote]) {
            guard
                offset == 0
                    || !(SyntaxEngine.isWord(bytes[offset - 1]) || (48...57).contains(bytes[offset - 1]))
            else {
                return nil
            }
            while quote < min(bytes.count, offset + 2), "rRuUbBfFtT".utf8.contains(bytes[quote]) {
                quote += 1
            }
            let prefix = String(decoding: bytes[offset..<quote], as: UTF8.self).lowercased()
            guard ["r", "u", "b", "f", "t", "ur", "br", "rb", "fr", "rf", "tr", "rt"].contains(prefix) else {
                return nil
            }
        }
        guard quote < bytes.count, [34, 39].contains(bytes[quote]) else {
            return nil
        }
        let triple =
            quote + 2 < bytes.count && bytes[quote + 1] == bytes[quote] && bytes[quote + 2] == bytes[quote]
        let formatted = bytes[offset..<quote].contains {
            [70, 102, 84, 116].contains($0)
        }
        return (
            PythonLiteral(
                quote: bytes[quote],
                triple: triple,
                formatted: formatted
            ),
            quote + (triple ? 3 : 1)
        )
    }

    /// 业务作用：完整匹配当前字符串终止符，单个引号不提前关闭三引号区域。
    /// 参数说明:
    /// - bytes: 当前物理行字节。
    /// - offset: 候选终止位置。
    /// - literal: 当前已进入的字符串类型。
    /// 返回：当前字节开始具有完整终止标记时为真。
    private static func matchesQuote(_ bytes: [UInt8], at offset: Int, literal: PythonLiteral) -> Bool {
        guard bytes[offset] == literal.quote else {
            return false
        }
        return !literal.triple
            || (offset + 2 < bytes.count && bytes[offset + 1] == literal.quote
                && bytes[offset + 2] == literal.quote)
    }

    /// 业务作用：将 Python 数值中的进制、分隔符、小数和指数保留在同一呈现范围。
    /// 参数说明:
    /// - bytes: 当前物理行字节。
    /// - offset: 数值起始字节。
    /// 返回：第一个不再属于当前数值的字节边界。
    private static func numberEnd(_ bytes: [UInt8], at offset: Int) -> Int {
        var cursor = offset + 1
        var previous = bytes[offset]
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if (48...57).contains(byte) || "abcdefABCDEFxXoObBeEjJ._".utf8.contains(byte)
                || ([43, 45].contains(byte) && [69, 101].contains(previous))
            {
                previous = byte
                cursor += 1
            }
            else {
                break
            }
        }
        return cursor
    }
}
