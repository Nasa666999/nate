import Foundation

extension TOMLScanner {
    /// 业务作用：普通及三引号值采用原生闭合、转义和真实行尾错误规则，未结束显示片段不改变类别。
    /// 参数说明: 无。
    /// 返回：关闭普通值后需要以键名重新解释当前位置时为真。
    mutating func string() throws -> Bool {
        let triple = state.mode == 11 || state.mode == 12
        let double = state.mode == 10 || state.mode == 12
        if state.atLineStart && !triple {
            try setMode(0)
        }
        else if atLineEnd && !triple {
            state.mode = 15
        }
        else if current == 92 && double {
            let following = try next()
            if following != 10, following != 13 {
                state.escapeOuter = state.mode
                state.escapeDigits = following == 120 ? 3 : (following == 117 ? 5 : (following == 85 ? 9 : 1))
                try setMode(13)
                try advance()
            }
        }
        else if current == (double ? 34 : 39), try !triple || tripleQuote() {
            while try current == next() {
                try advance()
            }
            try advance()
            if !triple, try isKey(keyword: false) {
                state.keyState = 0
                return true
            }
            try setMode(0)
        }
        return false
    }

    /// 业务作用：三引号只由同一固定原文中相邻的三个同类引号开启或关闭。
    /// 参数说明: 无。
    /// 返回：三个相邻原字节均为当前引号时为真，来源不足时拒绝。
    mutating func tripleQuote() throws -> Bool {
        guard current == 34 || current == 39 else {
            return false
        }
        return try UInt32(relativeByte(1)) == current && UInt32(relativeByte(2)) == current
    }
}
