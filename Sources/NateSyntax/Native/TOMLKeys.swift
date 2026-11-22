import Foundation
import NateCore

extension TOMLScanner {
    /// 业务作用：TOML inline key 依据完整原生后继确认，跨物理空白的读取仍受同源前瞻预算限制。
    /// 参数说明: 无。
    /// 返回：原生空白规则之后的首个字节或真实结束哨兵；证据不足时拒绝。
    mutating func lineNext() throws -> UInt32 {
        if !Self.space(current) {
            return current
        }
        if cursor + 1 == physicalEnd {
            return 0
        }
        let following = try next()
        if !Self.space(following) {
            return following
        }
        guard base <= Int.max - physicalEnd else {
            throw NateError.invalidRange
        }
        let limit = base + physicalEnd
        var position = 2
        while position < limit {
            let value = UInt32(try relativeByte(position))
            if !Self.space(value) {
                return value
            }
            position += 1
        }
        return 0
    }

    /// 业务作用：inline table 名称优先于值类别，普通标识符再按七字节原生候选确认关键字。
    /// 参数说明:
    /// - keyword: 当前类别为普通标识符，需要匹配关键字。
    /// 返回：完整后继将当前段确认为键时为真；其它情况封闭当前值段。
    mutating func isKey(keyword: Bool) throws -> Bool {
        if state.braceCount > 0, [61, 46, 45].contains(try lineNext()) {
            state.mode = 6
            return true
        }
        if keyword {
            let candidate = Data(
                state.prefix.prefix(7).prefix(while: {
                    $0 != 0
                }).map {
                    $0 >= 65 && $0 <= 90 ? $0 + 32 : $0
                }
            )
            if try rules.contains(candidate, group: 0, budget: &budget) {
                state.mode = 3
            }
        }
        try setMode(0)
        return false
    }

    /// 业务作用：表头及键名各自保留引用和点号作用域，完整后继才能收束键名。
    /// 参数说明: 无。
    /// 返回：点号分段需要重新解释当前位置时为真，其余路径继续本轮消费。
    mutating func keyOrTable() throws -> Bool {
        if state.atLineStart {
            try setMode(0)
            return false
        }
        if state.keyState == 1 {
            if current == 39 {
                state.keyState = 0
                try advance()
            }
        }
        else if state.keyState == 2 {
            if current == 92 {
                try advance()
            }
            else if current == 34 {
                state.keyState = 0
                try advance()
            }
        }
        guard state.keyState == 0 else {
            return false
        }
        if current == 39 {
            state.keyState = 1
        }
        else if current == 34 {
            state.keyState = 2
        }
        else if current == 46 {
            if state.mode == 5 {
                guard state.tableLevel < 65_536 else {
                    throw NateError.message("TOML 表头层级超过完整容量。")
                }
                state.tableLevel += 1
            }
            else {
                state.previousNonWhite = 46
                try setMode(8)
                try advance()
                try setMode(6)
                return true
            }
        }
        else if state.mode == 5, current == 93 {
            state.keyState = 3
            try advance()
            if current == 93 {
                try advance()
            }
            if try lineNext() == 35 {
                try setMode(0)
            }
        }
        else if state.mode == 6, !Self.unquoted(current) {
            let following = try lineNext()
            if following == 61 || following != 46 && state.previousNonWhite != 46 {
                state.keyState = 3
                try setMode(0)
            }
        }
        return false
    }
}
