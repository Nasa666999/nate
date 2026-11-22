import Foundation
import NateCore

struct SQLScanner {
    let bytes: [UInt8]
    let base: Int
    let rules: SQLRules
    let snapshot: DocumentSnapshot?
    var budget: ANSILexingBudget
    var state: SQLLexicalState
    var cursor = 0
    var tokens: [SyntaxToken] = []

    /// 业务作用：SQL 完整物理分类保持文档命令、跨行引号与 Q operator 的独立语义。
    /// 参数说明: 无。
    /// 返回：完整有界词元和下一检查点；来源不足或预算耗尽时抛错以丢弃本轮结果。
    mutating func scan() throws {
        try budget.check()
        while cursor < bytes.count {
            try budget.consume()
            let byte = bytes[cursor]
            let next = cursor + 1 < bytes.count ? bytes[cursor + 1] : 0
            if state.closingQuotePending {
                // 换行补码已由同源后继证明闭合，下一物理行的单引号必须先消费，不能另开普通字符串。
                guard state.mode == 24, byte == 39 else {
                    throw NateError.message("SQL 的跨行 Q 引号缺少已确认的闭合字节。")
                }
                try consume(1, style: 24)
                state.closingQuotePending = false
                state.mode = 0
                continue
            }
            if [2, 9, 13].contains(state.mode) {
                if state.lineCommentEnded {
                    state.mode = 0
                    state.lineCommentEnded = false
                }
                else {
                    try consume(scalarWidth(at: cursor), style: state.mode)
                    continue
                }
            }
            if state.mode == 1 || state.mode == 3 {
                if byte == 42, next == 47 {
                    let style = state.mode
                    try consume(2, style: style)
                    state.mode = 0
                }
                else if state.mode == 3, byte == 64 || byte == 92,
                    Self.isSpace(state.previousScalar) || state.previousScalar == 42,
                    !Self.isSpace(try sourceScalar(at: cursor + 1))
                {
                    try documentation()
                }
                else {
                    try consume(scalarWidth(at: cursor), style: state.mode)
                }
                continue
            }
            if state.mode == 6 || state.mode == 7 {
                let style = state.mode
                let quote: UInt8 = style == 6 ? 34 : 39
                if byte == 92 {
                    let count = cursor + 1 < bytes.count ? 1 + scalarWidth(at: cursor + 1) : 1
                    try consume(count, style: style)
                }
                else if byte == quote {
                    if next == quote {
                        try consume(2, style: style)
                    }
                    else {
                        try consume(1, style: style)
                        state.mode = 0
                    }
                }
                else {
                    try consume(scalarWidth(at: cursor), style: style)
                }
                continue
            }
            if state.mode == 24 {
                try qLiteral()
                continue
            }
            if (byte == 113 || byte == 81), next == 39 {
                state.mode = 24
                let opening = try sourceScalar(at: cursor + 2)
                switch opening {
                case 60:
                    state.qComplement = 62
                case 40:
                    state.qComplement = 41
                case 123:
                    state.qComplement = 125
                case 91:
                    state.qComplement = 93
                default:
                    state.qComplement = opening
                }
                try consume(2, style: 24)
            }
            else if Self.digit(byte) || byte == 46 && Self.digit(next)
                || (byte == 45 || byte == 43) && Self.digit(next)
                    && !(48...57).contains(state.previousScalar)
            {
                try number()
            }
            else if Self.wordStart(byte) {
                try word()
            }
            else if byte == 47, next == 42 {
                state.mode = cursor + 2 < bytes.count && [42, 33].contains(bytes[cursor + 2]) ? 3 : 1
                try consume(2, style: state.mode)
            }
            else if byte == 45, next == 45 {
                state.mode = 2
                state.lineCommentEnded = false
                try consume(2, style: 2)
            }
            else if byte == 39 || byte == 34 {
                state.mode = byte == 39 ? 7 : 6
                try consume(1, style: state.mode)
            }
            else {
                try consume(scalarWidth(at: cursor), style: Self.isOperator(byte) ? 10 : 0)
            }
        }
        if let last = bytes.last {
            state.physicalBoundary = last == 10 || last == 13
        }
        try budget.check()
    }

    /// 业务作用：SQL 名称在真实 EOF 同样确认词表身份，SQL*Plus 命令的后继文本采用独立行类别。
    /// 参数说明: 无。
    /// 返回：完整名称消费并发布其类别，SQL*Plus 注释或提示传播至真实下一行首。
    mutating func word() throws {
        let start = cursor
        var end = cursor + 1
        while end < bytes.count, Self.wordPart(bytes[end]) {
            try budget.consume()
            end += 1
        }
        let style = try rules.identifier(bytes[start..<end], budget: &budget)
        let prefix = bytes[start..<end].prefix(3).map { byte in
            byte >= 65 && byte <= 90 ? byte + 32 : byte
        }
        try consume(end - start, style: style)
        if style == 8, prefix == Array("rem".utf8) || prefix == Array("pro".utf8) {
            state.mode = prefix == Array("rem".utf8) ? 13 : 9
            state.lineCommentEnded = false
        }
    }

    /// 业务作用：数字沿原生外观接纳点和指数符号，不以数值求值改变后继范围。
    /// 参数说明: 无。
    /// 返回：完整数字外观取得数字样式，后继非数字字节由主扫描继续解释。
    mutating func number() throws {
        let start = cursor
        var end = cursor + 1
        while end < bytes.count {
            try budget.consume()
            let byte = bytes[end], previous = bytes[end - 1]
            guard
                Self.digit(byte) || byte == 46 || byte == 69 || byte == 101
                    || (byte == 43 || byte == 45) && (previous == 69 || previous == 101)
            else {
                break
            }
            end += 1
        }
        try consume(end - start, style: 4)
    }
}
