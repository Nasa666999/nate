import Foundation
import NateCore

extension CLexing {
    static let rawPrefixes = ["u8R\"", "uR\"", "UR\"", "LR\"", "R\""].map {
        Array($0.utf8)
    }
    static let quotedPrefixes = ["u8\"", "u\"", "U\"", "L\"", "\"", "u8'", "u'", "U'", "L'", "'"].map {
        Array($0.utf8)
    }

    /// 业务作用：原始字面、逐字字面和编码前缀只在完整词元起点识别，普通名称中的 R 不授予字符串身份。
    /// 参数说明: 无。
    /// 返回：合法字面起始完整消费时为真，否则原位置保留给普通词元处理。
    mutating func beginLiteral() throws -> Bool {
        if !state.preprocessor, bytes[cursor] == 64, cursor + 1 < bytes.count, bytes[cursor + 1] == 34 {
            state.verbatim = true
            state.expectsHeader = false
            try emit(cursor, cursor + 2, kind: .string, style: "verbatim")
            cursor += 2
            return true
        }
        guard [34, 39, 117, 85, 76, 82].contains(bytes[cursor]) else {
            return false
        }
        for prefix in Self.rawPrefixes where prefix[0] == bytes[cursor] {
            guard try matches(prefix, at: cursor) else {
                continue
            }
            var end = cursor + prefix.count
            var delimiter: [UInt8] = []
            while end < bytes.count, bytes[end] != 40 {
                try budget.consume()
                let byte = bytes[end]
                guard delimiter.count < 16, byte >= 33, byte <= 126, byte != 41, byte != 92 else {
                    return false
                }
                delimiter.append(byte)
                end += 1
            }
            guard end < bytes.count, bytes[end] == 40 else {
                return false
            }
            state.rawEnding = [41] + delimiter + [34]
            state.rawMatched = 0
            state.rawVisibleBeforeMatch = nil
            state.expectsHeader = false
            literalStart = cursor
            try emit(cursor, end + 1, kind: .string, style: "raw")
            cursor = end + 1
            return true
        }
        for prefix in Self.quotedPrefixes where prefix[0] == bytes[cursor] {
            guard try matches(prefix, at: cursor) else {
                continue
            }
            state.quote = prefix.last
            state.escape = false
            state.escapeDigits = 0
            state.escapeRadix = nil
            state.expectsHeader = false
            literalStart = cursor
            try emit(
                cursor,
                cursor + prefix.count,
                kind: .string,
                style: state.quote == 39 ? "character" : "string"
            )
            cursor += prefix.count
            return true
        }
        return false
    }

    /// 业务作用：逐字字符串按成对双引号保留字面引号，反斜杠和物理换行均不结束正文身份。
    /// 参数说明: 无。
    /// 返回：推进当前原字节或完整双引号对；仅独立双引号解除跨行字符串状态。
    mutating func verbatimByte() throws {
        let byte = bytes[cursor]
        let paired = byte == 34 && cursor + 1 < bytes.count && bytes[cursor + 1] == 34
        let width = paired ? 2 : max(1, newlineWidth(at: cursor))
        // 独立闭合引号只交接词法状态，不遮掉字面正文给后续正则留下的前置字符。
        try emit(
            cursor,
            cursor + width,
            kind: .string,
            style: "verbatim",
            updatesContext: byte != 34 || paired
        )
        cursor += width
        if byte == 34 && !paired {
            state.verbatim = false
        }
        if byte == 10 || byte == 13 {
            endLogicalLine()
        }
        else {
            state.logicalStart = false
        }
    }

    /// 业务作用：原始字面只按精确结束定界符关闭，反斜线和源码换行均保留字面含义。
    /// 参数说明: 无。
    /// 返回：推进一个原字节，完整定界符匹配后解除原始字面状态。
    mutating func rawByte() throws {
        let byte = bytes[cursor]
        state.logicalStart = false
        let previous = state.previousNonWhite
        if state.rawMatched == 0, byte == 41 {
            state.rawVisibleBeforeMatch = previous
        }
        try emit(cursor, cursor + 1, kind: .string, style: "raw")
        if byte == state.rawEnding[state.rawMatched] {
            state.rawMatched += 1
        }
        else {
            state.rawMatched = byte == 41 ? 1 : 0
            state.rawVisibleBeforeMatch = byte == 41 ? previous : nil
        }
        cursor += 1
        if state.rawMatched == state.rawEnding.count {
            // 整个原始定界符在一次状态交接中消费，后续正则资格沿用字面正文最后的可见字符。
            if let previous = state.rawVisibleBeforeMatch {
                state.previousNonWhite = previous
            }
            state.rawEnding = []
            state.rawMatched = 0
            state.rawVisibleBeforeMatch = nil
        }
        if byte == 10 || byte == 13 {
            endLogicalLine()
        }
    }

    /// 业务作用：普通字符串、字符和头文件名分别持有关闭规则，未续行的物理换行不能泄漏引号状态。
    /// 参数说明: 无。
    /// 返回：推进完整字面范围，普通未闭合行明确使用错误样式，仍不修改正文。
    mutating func quotedByte() throws {
        let ending = newlineWidth(at: cursor)
        if ending > 0 {
            try emit(cursor, cursor + ending, kind: .string, style: "invalid")
            for index in tokens.indices
            where tokens[index].kind == .string && tokens[index].range.lower >= base + literalStart {
                try budget.consume()
                tokens[index] = SyntaxToken(
                    range: tokens[index].range,
                    kind: .string,
                    lexicalStyle: "c:invalid"
                )
            }
            state.quote = nil
            state.header = false
            state.escape = false
            state.escapeDigits = 0
            state.escapeRadix = nil
            endLogicalLine()
            cursor += ending
            return
        }
        let byte = bytes[cursor]
        let style = state.header ? "header" : (state.quote == 39 ? "character" : "string")
        if state.escapeDigits > 0, let radix = state.escapeRadix {
            if Self.escapeDigit(byte, radix: radix) {
                try emit(cursor, cursor + 1, kind: .string, style: "escape")
                state.escapeDigits -= 1
                cursor += 1
                return
            }
            state.escapeDigits = 0
            state.escapeRadix = nil
        }
        if state.header {
            try emit(cursor, cursor + 1, kind: .string, style: style)
            if byte == 62 {
                state.header = false
            }
        }
        else if state.escape {
            try emit(cursor, cursor + 1, kind: .string, style: "escape")
            state.escape = false
            if byte == 120 {
                state.escapeRadix = 16
                state.escapeDigits = Int.max
            }
            else if byte == 117 || byte == 85 {
                state.escapeRadix = 16
                state.escapeDigits = byte == 117 ? 4 : 8
            }
            else if byte >= 48 && byte <= 55 {
                state.escapeRadix = 8
                state.escapeDigits = 2
            }
        }
        else if byte == 92 {
            try emit(cursor, cursor + 1, kind: .string, style: "escape")
            state.escape = true
        }
        else {
            // 闭合引号与下个状态在同一步交接，普通正文与转义引号仍正常推进前文。
            try emit(cursor, cursor + 1, kind: .string, style: style, updatesContext: byte != state.quote)
            if byte == state.quote {
                state.quote = nil
            }
        }
        cursor += 1
    }

    /// 业务作用：转义片段只延续规定进制的原始字符，不能吞掉后续引号或普通字符串内容。
    /// 参数说明:
    /// - byte: 当前原始 ASCII 字节。
    /// - radix: 当前转义采用的八进制或十六进制。
    /// 返回：可以延续当前转义数值时为真。
    static func escapeDigit(_ byte: UInt8, radix: UInt8) -> Bool {
        if radix == 8 {
            return byte >= 48 && byte <= 55
        }
        return byte >= 48 && byte <= 57 || byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102
    }

    /// 业务作用：字面前缀和定界符比较计入当前行预算，不能越过快照边界读取。
    /// 参数说明:
    /// - literal: 有限原字节标记。
    /// - offset: 当前行内起点。
    /// 返回：完整标记匹配时为真，范围不足或原字节不同为假。
    mutating func matches(_ literal: [UInt8], at offset: Int) throws -> Bool {
        guard literal.count <= bytes.count - offset else {
            return false
        }
        for index in literal.indices {
            try budget.consume()
            if bytes[offset + index] != literal[index] {
                return false
            }
        }
        return true
    }
}
