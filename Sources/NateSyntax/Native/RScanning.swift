import Foundation

extension RLexing {
    /// 业务作用：R 按独立类别推进完整物理范围，原始字符串及转义上下文随同源检查点一起传播。
    /// 参数说明: 无。
    /// 返回：完整原字节分类和后继状态，取消或预算不足时由外层丢弃全部局部结果。
    mutating func scan() throws {
        while cursor < bytes.count || documentEnd && cursor == bytes.count {
            try budget.consume()
            if state.mode == 15 {
                if try terminateEscape() {
                    continue
                }
            }
            else {
                try terminate()
            }
            // 原生前移可能到达尚未读取的下一物理行，范围外哨兵不能改变该行的词法状态。
            if cursor >= bytes.count, !documentEnd {
                break
            }
            if state.mode == 0 {
                try enter()
            }
            advance()
        }
        try change(state.mode)
    }

    /// 业务作用：类别在真实原文边界结束后，同一位置仍可开始后继代码，完整字面保持独立不透明状态。
    /// 参数说明: 无。
    /// 返回：当前已确认片段完成分类，命名运算符缺少闭合时整段转为原生未闭合类别。
    private mutating func terminate() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        switch state.mode {
        case 8:
            try change(0)
        case 5:
            if [101, 69, 112, 80].contains(current), Self.digit(next) || next == 43 || next == 45 {
                cursor += 1
            }
            else if !Self.hexadecimal(current), !(current == 46 && Self.digit(next)) {
                if current == 76 || current == 105 {
                    cursor += 1
                }
                try change(0)
            }
        case 9:
            if !Self.word(current), current != 46 {
                classifyIdentifier()
                try change(0)
            }
        case 1:
            if current == 10 || current == 13 {
                try change(0)
            }
        case 6, 7, 12:
            if current == 92 {
                try beginEscape()
            }
            else if current == (state.mode == 6 ? 34 : (state.mode == 7 ? 39 : 96)) {
                cursor += 1
                try change(0)
            }
        case 13, 14:
            try terminateRaw()
        case 10:
            if current == 37 {
                cursor += 1
                try change(0)
            }
            else if lineEnd {
                state.mode = 11
            }
        case 11:
            if state.continuation.atLineStart {
                try change(0)
            }
        default:
            break
        }
    }

    /// 业务作用：R 代码区优先识别数字及完整原始字面开端，其后分别识别名称、注释、引号和操作符。
    /// 参数说明: 无。
    /// 返回：当前真实起点进入原生类别，缺少原始开端时保留独立前缀和普通引号状态。
    private mutating func enter() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        if Self.digit(current) || current == 46 && Self.digit(next) {
            try change(5)
            if current == 48, next == 120 || next == 88 {
                cursor += 1
            }
        }
        else if current == 114 || current == 82, next == 34 || next == 39 {
            if let opening = try rawOpening(at: cursor + 2) {
                state.continuation.rawDelimiter = opening.delimiter
                state.continuation.dashes = opening.dashes
                try change(next == 34 ? 13 : 14)
                cursor += opening.dashes + 2
            }
            else {
                try change(9)
                cursor += 1
                try change(next == 34 ? 6 : 7)
            }
        }
        else if Self.word(current) {
            try change(9)
        }
        else if current == 35 {
            try change(1)
        }
        else if current == 34 || current == 39 || current == 96 {
            try change(current == 34 ? 6 : (current == 39 ? 7 : 12))
        }
        else if current == 37 {
            try change(10)
        }
        else if Self.isOperator(current) {
            try change(8)
        }
    }

    /// 业务作用：只消费真实标量才更新物理行首标志，EOF 哨兵不能冒充输入或制造新的行首。
    /// 参数说明: 无。
    /// 返回：前移到后继标量或完成 EOF，CRLF 两字节共同构成一次物理行结束。
    private mutating func advance() {
        if cursor < bytes.count {
            state.continuation.atLineStart =
                byte(cursor) == 10 || byte(cursor) == 13 && byte(cursor + 1) != 10
            cursor += width(cursor)
        }
        else {
            cursor += 1
        }
    }
}
