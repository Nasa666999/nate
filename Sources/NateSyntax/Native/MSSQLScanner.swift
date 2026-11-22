import Foundation
import NateCore

struct MSSQLScanner {
    let bytes: [UInt8]
    let base: Int
    let rules: MSSQLRules
    let snapshot: DocumentSnapshot?
    var budget: ANSILexingBudget
    var state: MSSQLLexicalState
    var cursor = 0
    var tokens: [SyntaxToken] = []

    /// 业务作用：按 T-SQL 原生状态推进完整物理范围，保留引用名称、嵌套注释与类型优先资格。
    /// 参数说明: 无。
    /// 返回：完整有界词元及后继状态；来源不足、取消或容量耗尽时抛错以丢弃本轮结果。
    mutating func scan() throws {
        try budget.check()
        // 已返回的未终止名称不能反向改色，无全文来源的空白也不能预判未来，须停止连续片段。
        guard ![6, 7, 12].contains(state.mode),
            snapshot != nil || state.mode != 15
        else {
            throw NateError.message("T-SQL 连续范围缺少完整名称或空白后继来源。")
        }
        while cursor < bytes.count {
            try budget.consume()
            let byte = bytes[cursor]
            let next = cursor + 1 < bytes.count ? bytes[cursor + 1] : 0
            if state.mode == 1 {
                if byte == 47, next == 42 {
                    // 嵌套深度必须完整保留；超量不能提前开放尚未闭合的注释为代码。
                    guard state.commentDepth < 4096 else {
                        throw NateError.message("T-SQL 嵌套注释超过 4096 层。")
                    }
                    state.commentDepth += 1
                }
                else if byte == 47, state.previousByte == 42 {
                    if state.commentDepth > 0 {
                        state.commentDepth -= 1
                    }
                    else if let origin = state.commentOrigin, base + cursor > origin + 2 {
                        try consume(1, style: 1)
                        state.mode = 0
                        state.commentOrigin = nil
                        continue
                    }
                }
                try consume(scalarWidth(), style: 1)
            }
            else if state.mode == 2 {
                if byte == 10 || byte == 13 {
                    state.mode = 0
                }
                else {
                    try consume(scalarWidth(), style: 2)
                    continue
                }
            }
            else if [4, 8, 16].contains(state.mode) {
                let style = state.mode
                let closer: UInt8 = style == 4 ? 39 : (style == 8 ? 34 : 93)
                if byte == closer {
                    if style != 16, next == closer {
                        try consume(2, style: style)
                    }
                    else {
                        try consume(1, style: style)
                        state.mode = style == 4 ? 0 : 15
                        state.preferredEnd = nil
                    }
                }
                else {
                    try consume(scalarWidth(), style: style)
                }
            }
            else {
                if Self.wordStart(byte) {
                    try word(global: false, variable: false)
                }
                else if byte == 64 {
                    try word(global: next == 64, variable: next != 64)
                }
                else if byte == 47, next == 42 {
                    state.mode = 1
                    state.commentDepth = 0
                    state.commentOrigin = base + cursor
                    state.preferredEnd = nil
                    try consume(1, style: 1)
                }
                else if byte == 45, next == 45 {
                    state.mode = 2
                    state.preferredEnd = nil
                    try consume(1, style: 2)
                }
                else if byte == 39 || byte == 34 || byte == 91 {
                    state.mode = byte == 39 ? 4 : (byte == 34 ? 8 : 16)
                    state.preferredEnd = nil
                    try consume(1, style: state.mode)
                }
                else if Self.isOperator(byte) {
                    state.mode = 0
                    state.preferredEnd = nil
                    try consume(1, style: 5)
                }
                else {
                    let style = state.mode == 15 ? try preferredStyle() : 0
                    try consume(scalarWidth(), style: style)
                }
            }
        }
        try budget.check()
    }

    /// 业务作用：完整名称在终止字节出现后才取得语句或类型身份，真实 EOF 保留原生未终止类别。
    /// 参数说明:
    /// - global: 是否读取允许多个 at 符号的全局名称。
    /// - variable: 是否为单 at 符号变量。
    /// 返回：当前名称完整消费，普通未知名称与变量为后续名称保留类型优先上下文。
    mutating func word(global: Bool, variable: Bool) throws {
        let start = cursor
        var end = cursor + 1
        while end < bytes.count, Self.wordPart(bytes[end]) || global && bytes[end] == 64 {
            try budget.consume()
            end += 1
        }
        let terminated = end < bytes.count
        let style: UInt8
        if variable {
            style = 7
        }
        else if !terminated {
            style = global ? 12 : 6
        }
        else {
            style = rules.identifier(bytes[start..<end], prefersType: state.mode == 15, global: global)
        }
        try consume(end - start, style: style)
        state.preferredEnd = nil
        if !terminated {
            state.mode = global ? 12 : (variable ? 7 : 6)
        }
        else if global {
            state.mode = 0
        }
        else {
            state.mode = style == 6 || style == 7 ? 15 : 0
        }
    }
}
