import Foundation

extension RLexing {
    /// 业务作用：R 原始字符串必须在同一物理行具有完整开端，连接符数量与闭合括号一起传播。
    /// 参数说明:
    /// - start: 引号之后的首个候选原字节。
    /// 返回：完整开端的闭合括号和连接符数量；没有合法括号时为空，不借后续行猜测开端。
    mutating func rawOpening(at start: Int) throws -> (delimiter: UInt8, dashes: Int)? {
        var index = start
        while byte(index) == 45 {
            try budget.consume()
            index += 1
        }
        let delimiter: UInt8
        switch byte(index) {
        case 40:
            delimiter = 41
        case 91:
            delimiter = 93
        case 123:
            delimiter = 125
        default:
            return nil
        }
        return (delimiter, index - start)
    }

    /// 业务作用：原始字符串只由对应括号、相同连接符数及原引号一起闭合，部分候选仍归属原字面。
    /// 参数说明: 无。
    /// 返回：完整闭合时重置原始状态并回到代码；否则沿已经消费的原字节继续读取。
    mutating func terminateRaw() throws {
        while byte(cursor) == state.continuation.rawDelimiter {
            try budget.consume()
            cursor += 1
            var remaining = state.continuation.dashes
            while remaining > 0, byte(cursor) == 45 {
                try budget.consume()
                remaining -= 1
                cursor += 1
            }
            let quote: UInt8 = state.mode == 13 ? 34 : 39
            if remaining == 0, byte(cursor) == quote {
                state.continuation.rawDelimiter = 0
                state.continuation.dashes = 0
                cursor += 1
                try change(0)
                break
            }
        }
    }

    /// 业务作用：普通引号与反引号中的反斜杠开始独立转义类别，完整数字预算随原外层类别保存。
    /// 参数说明: 无。
    /// 返回：当前转义开端已确定；物理换行不沿用丢失外层语义的独立转义类别。
    mutating func beginEscape() throws {
        let next = byte(cursor + 1)
        state.continuation.escapeOuter = state.mode
        state.continuation.escapeDigits = next == 120 ? 3 : (next == 117 ? 5 : (next == 85 ? 9 : 1))
        state.continuation.escapeHex = true
        state.continuation.escapeBraced = false
        if (48...55).contains(next) {
            state.continuation.escapeDigits = 3
            state.continuation.escapeHex = false
        }
        try change(15)
        cursor += 1
        if byte(cursor + 1) == 123, byte(cursor) == 117 || byte(cursor) == 85 {
            state.continuation.escapeBraced = true
            cursor += 1
        }
        else if byte(cursor) == 10 || byte(cursor) == 13 {
            try change(state.continuation.escapeOuter)
        }
    }

    /// 业务作用：数字转义在原生长度或字符边界结束，括号形式只额外消费实际闭合花括号。
    /// 参数说明: 无。
    /// 返回：转义已结束时为真，调用方在原外层类别重新处理同一后继字符；否则继续当前转义。
    mutating func terminateEscape() throws -> Bool {
        state.continuation.escapeDigits -= 1
        let current = byte(cursor)
        let allowed = state.continuation.escapeHex ? Self.hexadecimal(current) : (48...55).contains(current)
        guard state.continuation.escapeDigits <= 0 || !allowed else {
            return false
        }
        if state.continuation.escapeBraced, current == 125 {
            cursor += 1
        }
        try change(state.continuation.escapeOuter)
        return true
    }
}
