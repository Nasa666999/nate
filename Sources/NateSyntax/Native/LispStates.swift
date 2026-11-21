import Foundation

extension LispLexing {
    /// 业务作用：逐原字节传播读取状态，字符串、注释和读取宏使用各自终止规则。
    /// 参数说明: 无。
    /// 返回：当前完整范围分类完成；未完成名称保留其末尾状态，不凭 EOF 猜测关键字。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            let current = byte(cursor)
            let next = byte(cursor + 1)
            switch state.style {
            case 0:
                try ordinary(current, next)
            case 9, 5:
                if !Self.word(current) {
                    if state.style == 9 {
                        try classify(cursor - 1)
                    }
                    else {
                        try paint(cursor - 1, state.style)
                    }
                    state.style = 0
                }
                try operatorAt(current, next)
            case 31:
                try dispatch(current, next)
            case 30:
                state.style =
                    Self.word(current) && (state.radix == -1 || Self.digit(current, radix: state.radix))
                    ? 11 : 0
            case 29:
                if Self.operation(current) {
                    try paint(cursor, 11)
                    state.style = 0
                }
                else if Self.word(current) {
                    try paint(cursor, 11)
                    state.style = 11
                }
                else {
                    state.style = 0
                }
            case 11:
                if !Self.word(current) || state.radix != -1 && !Self.digit(current, radix: state.radix) {
                    try paint(cursor - 1, state.style)
                    state.style = 0
                }
                try operatorAt(current, next)
            case 1:
                if current == 10 || current == 13 && next != 10 {
                    try paint(cursor - 1, state.style)
                    state.style = 0
                }
            case 12:
                if current == 124 && next == 35 {
                    cursor += 1
                    try paint(cursor, state.style)
                    state.style = 0
                }
            case 6:
                if current == 92 && [34, 39, 92].contains(next) {
                    cursor += 1
                }
                else if current == 34 {
                    try paint(cursor, state.style)
                    state.style = 0
                }
            default:
                break
            }
            cursor += 1
        }
        try paint(bytes.count - 1, state.style)
    }

    /// 业务作用：中性正文按读取前缀进入名称、符号、读取宏、字符串或注释，不运行任何表达式。
    /// 参数说明:
    /// - current: 当前原字节。
    /// - next: 下一原字节证据。
    /// 返回：必要的前缀封存完成，进入独立读取状态。
    mutating func ordinary(_ current: UInt8, _ next: UInt8) throws {
        if current == 35 {
            try paint(cursor - 1, state.style)
            state.radix = -1
            state.style = 31
        }
        else if current == 58 && Self.word(next) {
            try paint(cursor - 1, state.style)
            state.style = 5
        }
        else if Self.word(current) {
            try paint(cursor - 1, state.style)
            state.style = 9
        }
        else if current == 59 {
            try paint(cursor - 1, state.style)
            state.style = 1
        }
        else if Self.operation(current) {
            try operatorAt(current, next)
        }
        else if current == 34 {
            try paint(cursor - 1, state.style)
            state.style = 6
        }
    }

    /// 业务作用：操作符单独封存，引号后的名称取得符号身份，不把字符读取宏中的括号变成结构。
    /// 参数说明:
    /// - current: 当前候选操作符。
    /// - next: 引号后名称的首字节证据。
    /// 返回：操作符分类完成，非操作符保持现有状态。
    mutating func operatorAt(_ current: UInt8, _ next: UInt8) throws {
        guard Self.operation(current) else {
            return
        }
        try paint(cursor - 1, state.style)
        try paint(cursor, 10)
        if current == 39 && Self.word(next) {
            state.style = 5
        }
    }

    /// 业务作用：井号读取前缀根据紧随字符选择注释、进制、字符或条件名称，未知前缀回到正文。
    /// 参数说明:
    /// - current: 读取前缀后当前原字节。
    /// - next: 引号后名称的首字节证据。
    /// 返回：读取宏状态完整推进，非法前缀不被自动改写为合法数值。
    mutating func dispatch(_ current: UInt8, _ next: UInt8) throws {
        if current >= 48 && current <= 57 {
            return
        }
        if current != 114 && current != 82 && cursor - segment > 1 {
            state.style = 0
            return
        }
        switch current {
        case 124:
            state.style = 12
        case 111, 79, 120, 88, 98, 66:
            state.radix = current == 111 || current == 79 ? 8 : (current == 120 || current == 88 ? 16 : 2)
            state.style = 30
        case 92:
            state.style = 29
        case 58, 45, 43:
            state.style = 30
        case 39:
            if Self.word(next) {
                state.style = 11
            }
            else {
                try paint(cursor - 1, 0)
                try paint(cursor, 10)
                state.style = 0
            }
        default:
            if Self.operation(current) {
                try paint(cursor - 1, 0)
                try paint(cursor, 10)
            }
            state.style = 0
        }
    }
}
