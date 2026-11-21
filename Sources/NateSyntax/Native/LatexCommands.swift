import Foundation

extension LatexLexing {
    /// 业务作用：正文与两种数学模式共享转义入口，但只由各自匹配的关闭符解除数学状态。
    /// 参数说明: 无。
    /// 返回：推进当前符号及完整单字符命令，正文不被执行或改写。
    mutating func ordinary() throws {
        let current = byte(cursor)
        let next = byte(cursor + 1)
        if current == 92 {
            try paint(through: cursor - 1, style: state.style)
            let length =
                snapshot.map {
                    $0.text.byteCount - base
                } ?? bytes.count
            if state.mode == 0 && cursor + 1 >= length {
                return
            }
            if Self.letter(next) {
                if state.mode != 0, suffix(cursor + 3, "\\end") {
                    var end = cursor + 4
                    if try validTag(&end), state.mode == 1 ? suffix(end, "{math}") : mathEnvironment(end) {
                        state.mode = 0
                    }
                }
                state.style = 1
            }
            else if Self.special(next) {
                if cursor + 1 < length {
                    try paint(through: cursor + 1, style: 10)
                    cursor += 1
                }
            }
            else if next == 13 || next == 10 {
                try paint(through: cursor, style: 12)
            }
            else if next < 128 {
                try paint(through: cursor + 1, style: 9)
                if state.mode == 0 && (next == 40 || next == 91) {
                    state.mode = next == 40 ? 1 : 2
                    reset()
                }
                else if state.mode == 1 && next == 41 || state.mode == 2 && next == 93 {
                    state.mode = 0
                    reset()
                }
                cursor += 1
            }
        }
        else if current == 36 {
            try paint(through: cursor - 1, style: state.style)
            if state.mode != 1 && next == 36 {
                try paint(through: cursor + 1, style: 9)
                state.mode = state.mode == 0 ? 2 : 0
                cursor += 1
            }
            else {
                try paint(through: cursor, style: 9)
                if state.mode != 2 {
                    state.mode = state.mode == 0 ? 1 : 0
                }
            }
            reset()
        }
        else if current == 37 {
            try paint(through: cursor - 1, style: state.style)
            state.style = 4
        }
    }

    /// 业务作用：控制词结束后先确认可选参数，再决定环境或逐字入口，保持参数中的正文身份。
    /// 参数说明: 无。
    /// 返回：封存完整控制词并确定下一段状态。
    mutating func command() throws {
        guard !Self.letter(byte(cursor + 1)) else {
            return
        }
        try paint(through: cursor, style: 1)
        if try optionalArgument(cursor + 1) {
            state.style = 11
        }
        else if suffix(cursor, "\\begin") {
            state.style = 2
        }
        else if suffix(cursor, "\\end") {
            state.style = 5
        }
        else if suffix(cursor, "\\verb"), byte(cursor + 1) != 42, byte(cursor + 1) != 32 {
            state.verbatimDelimiter = byte(cursor + 1)
            state.style = 8
        }
        else {
            reset()
        }
    }

    /// 业务作用：环境标签完整验证后才允许改变数学或逐字状态，非法标签不会授予环境身份。
    /// 参数说明: 无。
    /// 返回：标签或首个非法字节分类完成，状态回到所属外部模式。
    mutating func tag() throws {
        let opening = state.style == 2
        var end = cursor
        let valid = try validTag(&end)
        cursor = end
        try paint(through: cursor, style: valid ? state.style : 12)
        reset()
        guard opening && valid else {
            return
        }
        if suffix(cursor, "{verbatim}") || suffix(cursor, "{lstlisting}") {
            state.style = 8
        }
        else if suffix(cursor, "{comment}") {
            state.style = 7
        }
        else if state.mode == 0 && suffix(cursor, "{math}") {
            state.mode = 1
            reset()
        }
        else if state.mode == 0 && mathEnvironment(cursor) {
            state.mode = 2
            reset()
        }
    }

    /// 业务作用：注释块和逐字正文只接受自己的结束环境，行内逐字文本缺少结束符时保留错误身份。
    /// 参数说明: 无。
    /// 返回：封存已闭合范围或保持跨行环境，NUL 仍作为原文参与规定的分隔判断。
    mutating func literal() throws {
        if byte(cursor) == 92 {
            if suffix(cursor + 3, "\\end") {
                var end = cursor + 4
                if try validTag(&end) {
                    let closes =
                        state.style == 7
                        ? suffix(end, "{comment}")
                        : suffix(end, "{verbatim}") || suffix(end, "{lstlisting}")
                    if closes {
                        try paint(through: cursor - 1, style: state.style)
                        state.style = 1
                    }
                }
            }
        }
        else if state.style == 8 && byte(cursor + 1) == state.verbatimDelimiter {
            let length = snapshot.map { $0.text.byteCount - base } ?? bytes.count
            if cursor + 1 == bytes.count && cursor + 1 < length {
                state.carriedStyle = 8
            }
            try paint(through: cursor + 1, style: 8)
            reset()
            state.verbatimDelimiter = 0
            cursor += 1
        }
        else if state.style == 8 && state.verbatimDelimiter != 0 && (byte(cursor) == 10 || byte(cursor) == 13)
        {
            try paint(through: cursor - 1, style: 12)
            reset()
            state.verbatimDelimiter = 0
        }
    }
}
