import Foundation
import NateCore

extension MSSQLScanner {
    /// 业务作用：T-SQL 名称只由原生 ASCII 字母、数字和下划线开端，不归一化其它字符。
    /// 参数说明:
    /// - byte: 已确认的原字节。
    /// 返回：名称可在该字节开始时为真。
    static func wordStart(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57 || byte >= 65 && byte <= 90
            || byte >= 97 && byte <= 122 || byte == 95
    }

    /// 业务作用：名称内部保留句点，复合名称不能被其中的局部关键字冒充。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：原生名称的合法后继时为真。
    static func wordPart(_ byte: UInt8) -> Bool {
        wordStart(byte) || byte == 46
    }

    /// 业务作用：仅原生运算符集合授予代码标点身份，引用列名中的同形符号保持不透明。
    /// 参数说明:
    /// - byte: 已确认处于代码区的原字节。
    /// 返回：该字节是独立运算符时为真。
    static func isOperator(_ byte: UInt8) -> Bool {
        "%^&*()-+=|{}[]:;<>,/?!~.".utf8.contains(byte)
    }

    /// 业务作用：对已验证 UTF-8 的原字节按完整标量推进，输出范围不拆开 Unicode 编码。
    /// 参数说明: 无。
    /// 返回：当前位置一个完整标量的字节数。
    func scalarWidth() -> Int {
        let first = bytes[cursor]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：词元同时固定原生类别和当前资源属性，完整原字节分类在容量允许时才保留。
    /// 参数说明:
    /// - count: 当前完整范围的字节数。
    /// - style: 已确认的原生样式。
    /// 返回：范围消费并加入有限词元；缺少属性或超过 65536 个片段时抛错。
    mutating func consume(_ count: Int, style: UInt8) throws {
        guard count > 0, count <= bytes.count - cursor,
            let attributes = rules.styles[String(style)]
        else {
            throw NateError.message("T-SQL 词元缺少完整范围或样式。")
        }
        try budget.consume()
        let kind: SyntaxKind
        switch style {
        case 1, 2:
            kind = .comment
        case 4, 8, 16:
            kind = .string
        case 3:
            kind = .number
        case 5:
            kind = .punctuation
        case 9...14:
            kind = .keyword
        default:
            kind = .text
        }
        let identity = "mssql:" + String(style)
        var lower = base + cursor
        if let previous = tokens.last, previous.lexicalStyle == identity,
            previous.range.upper == lower
        {
            lower = previous.range.lower
            tokens.removeLast()
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("T-SQL 单行超过 65536 个完整词元。")
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
        state.previousByte = bytes[cursor + count - 1]
        cursor += count
    }
}
