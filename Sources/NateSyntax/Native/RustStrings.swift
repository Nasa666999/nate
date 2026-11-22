import Foundation
import NateCore

extension RustLexing {
    /// 业务作用：嵌套块注释只由对应开闭标记改变深度，内层文档标记不改变外层样式。
    /// 参数说明: 无。
    /// 返回：闭合时回到代码，未闭合时保留深度及原注释类别；超深整份拒绝。
    mutating func blockComment() throws {
        let style = state.style
        while cursor < bytes.count {
            try budget.consume()
            let c = byte(cursor), n = byte(cursor + 1)
            if c == 42, n == 47 {
                cursor += 2
                state.depth -= 1
                if state.depth == 0 {
                    state.style = 0
                    break
                }
            }
            else if c == 47, n == 42 {
                guard state.depth < 128 else {
                    throw NateError.message("Rust 块注释嵌套超过 128 层，未采用部分样式。")
                }
                state.depth += 1
                cursor += 2
            }
            else {
                cursor += 1
            }
        }
        try paint(style)
    }

    /// 业务作用：行注释及首行 shebang 只覆盖真实 CR/LF 前的正文，显示分隔符不提前结束注释。
    /// 参数说明:
    /// - style: 普通或文档行注释的实际样式。
    /// 返回：光标停在真实行结束符或 EOF，结束符保持中性类别。
    mutating func lineComment(style: Int) throws {
        state.lineComment = true
        while cursor < bytes.count, ![10, 13].contains(byte(cursor)) {
            try budget.consume()
            cursor += 1
        }
        try paint(style)
    }

    /// 业务作用：原始字符串固定井号数量，非法前缀保留词法错误身份而不吞掉后续代码。
    /// 参数说明:
    /// - style: 普通、字节或 C 原始字符串的实际类别。
    /// 返回：合法开端进入独立原始状态，井号容量或时间不足整体失败。
    mutating func rawStart(style: Int) throws {
        cursor += 1
        state.hashes = 0
        while byte(cursor) == 35 {
            try budget.consume()
            guard state.hashes < 65_536 else {
                throw NateError.message("Rust 原始字符串井号数量超过 65536，未采用部分样式。")
            }
            state.hashes += 1
            cursor += 1
        }
        guard byte(cursor) == 34 else {
            try paint(20)
            return
        }
        state.style = style
        cursor += 1
        try rawLiteral()
    }

    /// 业务作用：原始字符串仅由引号及匹配数量的井号闭合，不解释反斜杠或代码标点。
    /// 参数说明: 无。
    /// 返回：未闭合时保留跨行状态；原始字节字符串遇到非 ASCII 时交还后续代码扫描。
    mutating func rawLiteral() throws {
        let style = state.style
        while cursor < bytes.count {
            try budget.consume()
            if byte(cursor) == 34 {
                cursor += 1
                var hashes = 0
                while hashes < state.hashes, byte(cursor) == 35 {
                    try budget.consume()
                    hashes += 1
                    cursor += 1
                }
                if hashes == state.hashes {
                    state.style = 0
                    break
                }
            }
            else if style == 22, byte(cursor) >= 128 {
                state.style = 0
                break
            }
            else {
                cursor += 1
            }
        }
        try paint(style)
    }

    /// 业务作用：普通、字节与 C 字符串使用各自转义许可，非法转义之后重新识别代码而不跨域染色。
    /// 参数说明: 无。
    /// 返回：合法闭合或非法内容解除当前字面状态，物理行结束仍保留未闭合字符串。
    mutating func stringLiteral() throws {
        let style = state.style
        while cursor < bytes.count {
            try budget.consume()
            let c = byte(cursor), n = byte(cursor + 1)
            if c == 34 {
                cursor += 1
                state.style = 0
                break
            }
            if c == 92 {
                if Self.validEscape(n) || n == 10 || n == 13 {
                    cursor += 2
                }
                else if n == 120 {
                    cursor += 2
                    if try !numericEscape(digits: 2, stopAsSoonAsComplete: true) {
                        state.style = 0
                        break
                    }
                }
                else if (n == 117 || n == 85), style != 21 {
                    cursor += 2
                    if try !unicodeEscape(long: n == 85, stopAsSoonAsComplete: true) {
                        state.style = 0
                        break
                    }
                }
                else {
                    cursor += 1
                    state.style = 0
                    break
                }
            }
            else if style == 21, c >= 128 {
                state.style = 0
                break
            }
            else {
                cursor += 1
            }
        }
        try paint(style)
    }

    /// 业务作用：字面转义采用基准的固定 ASCII 集合，不把任意反斜杠后继作为有效转义。
    /// 参数说明:
    /// - byte: 反斜杠之后的原字节。
    /// 返回：字符及字符串共同允许的简单转义时为真。
    static func validEscape(_ byte: UInt8) -> Bool {
        [110, 114, 116, 92, 39, 34, 48].contains(byte)
    }
}
