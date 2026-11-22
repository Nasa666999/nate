import Foundation
import NateCore

extension SQLScanner {
    /// 业务作用：SQL 名称采用原生 ASCII 字母与下划线开端，不把非 ASCII 文本拆成关键字。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：名称可在该字节开始时为真。
    static func wordStart(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95
    }

    /// 业务作用：SQL 名称内部接纳 ASCII 数字，默认句点保持独立运算符。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：该字节属于当前名称时为真。
    static func wordPart(_ byte: UInt8) -> Bool {
        wordStart(byte) || digit(byte)
    }

    /// 业务作用：数字开端与后继只按 ASCII 十进制字符确认。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：该字节属于 ASCII 数字时为真。
    static func digit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// 业务作用：文档命令的空白判断保留原生控制字符边界，NUL 不作为空白。
    /// 参数说明:
    /// - scalar: 当前完整 Unicode 标量。
    /// 返回：ASCII 空格或 Tab 至 CR 控制字符时为真。
    static func isSpace(_ scalar: UInt32) -> Bool {
        scalar == 32 || scalar >= 9 && scalar <= 13
    }

    /// 业务作用：SQL 代码标点采用原生运算符集合，引用区中的相同字节不取得结构资格。
    /// 参数说明:
    /// - byte: 已确认处于代码区的原字节。
    /// 返回：独立运算符时为真。
    static func isOperator(_ byte: UInt8) -> Bool {
        "%^&*()-+=|{}[]:;<>,/?!~.".utf8.contains(byte)
    }

    /// 业务作用：完整有效 UTF-8 分类按标量宽度推进，不拆开 Unicode 字形的编码字节。
    /// 参数说明:
    /// - offset: 当前完整片段中的标量开端。
    /// 返回：当前标量的 UTF-8 字节数。
    func scalarWidth(at offset: Int) -> Int {
        let first = bytes[offset]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：从完整有效片段恢复实际标量，名称和数字的前置上下文不以尾随编码字节代替。
    /// 参数说明:
    /// - offset: 已确认的标量开端。
    /// 返回：当前位置完整 Unicode 标量值。
    func scalar(at offset: Int) -> UInt32 {
        let width = scalarWidth(at: offset)
        if width == 1 {
            return UInt32(bytes[offset])
        }
        var value = UInt32(bytes[offset] & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
        for index in 1..<width {
            value = (value << 6) | UInt32(bytes[offset + index] & 63)
        }
        return value
    }

    /// 业务作用：每个词元同时保留原生身份、完整样式和结构不透明性，容量不足时拒绝整行。
    /// 参数说明:
    /// - count: 当前完整范围的原字节数。
    /// - style: 已确认的 SQL 原生类别。
    /// 返回：完整范围被消费并保留有限词元；缺少属性或超量时抛错。
    mutating func consume(_ count: Int, style: UInt8) throws {
        guard count > 0, count <= bytes.count - cursor,
            let attributes = rules.styles[String(style)]
        else {
            throw NateError.message("SQL 词元缺少完整范围或样式。")
        }
        try budget.consume()
        let kind: SyntaxKind
        switch style {
        case 1, 2, 3, 13, 15, 17, 18:
            kind = .comment
        case 6, 7, 9, 23, 24:
            kind = .string
        case 4:
            kind = .number
        case 10:
            kind = .punctuation
        case 5, 8, 16, 19...22:
            kind = .keyword
        default:
            kind = .text
        }
        let identity = "sql:" + String(style)
        var lower = base + cursor
        if let previous = tokens.last, previous.lexicalStyle == identity,
            previous.range.upper == lower
        {
            lower = previous.range.lower
            tokens.removeLast()
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("SQL 单行超过 65536 个完整词元。")
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(lower, base + cursor + count),
                kind: kind,
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: identity
            )
        )
        var last = cursor + count - 1
        while last > cursor, bytes[last] & 192 == 128 {
            last -= 1
        }
        state.previousScalar = scalar(at: last)
        if [2, 9, 13].contains(state.mode) {
            if bytes[last] == 10 {
                state.lineCommentEnded = true
            }
            else if bytes[last] == 13 {
                let following = try sourceByte(at: last + 1)
                state.lineCommentEnded = following != 10
            }
        }
        cursor += count
    }
}
