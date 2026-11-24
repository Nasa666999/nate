import Foundation
import NateCore

enum AutoItIndentationKind: Sendable, Equatable {
    case conditional, function, forLoop, whileLoop, doLoop, withBlock, switchBlock, selectBlock
}

enum AutoItIndentationStatement {
    case none
    case open(AutoItIndentationKind)
    case close(AutoItIndentationKind)
    case alternate(Bool)
    case branch(Bool)

    /// 业务作用：从已遮蔽字面和注释的完整逻辑语句识别结构职责，单行条件不创建跨行块。
    /// 参数说明:
    /// - code: 连续逻辑语句的有限原字节，字面以非空白哨兵保留表达式位置。
    /// - budget: 整批结构准备的共同额度。
    /// 返回：明确的块开端、闭合或分支；缺少完整结构证据时保留普通语句行为。
    static func parse(_ code: [UInt8], budget: inout AutoItIndentationBudget) throws -> Self {
        try budget.consume(code.count)
        let significant = code.indices.filter {
            code[$0] != 9 && code[$0] != 32 && code[$0] != 10 && code[$0] != 13
        }
        guard let first = significant.first, let last = significant.last else {
            return .none
        }
        let leading = word(code, at: first)
        guard !leading.value.isEmpty else {
            return .none
        }
        let rest = significant.first(where: { $0 >= leading.end })
        let hasOperand = rest != nil
        switch leading.value {
        case "if", "elseif":
            var start = last
            while start > leading.end && letter(code[start - 1]) {
                start -= 1
            }
            let trailing = word(code, at: start)
            guard trailing.value == "then", trailing.end == last + 1,
                let rest, rest < start, start > 0, !letter(code[start - 1]),
                !(48...57).contains(code[start - 1]), ![36, 64, 46].contains(code[start - 1])
            else {
                return .none
            }
            return leading.value == "if" ? .open(.conditional) : .alternate(false)
        case "else":
            return hasOperand ? .none : .alternate(true)
        case "func":
            guard let rest, letter(code[rest]) || code[rest] >= 128, code[last] == 41
            else {
                return .none
            }
            var opening = rest
            while opening <= last,
                letter(code[opening]) || (48...57).contains(code[opening]) || code[opening] >= 128
            {
                try budget.consume()
                opening += 1
            }
            while opening <= last && (code[opening] == 9 || code[opening] == 32) {
                try budget.consume()
                opening += 1
            }
            guard opening <= last, code[opening] == 40 else {
                return .none
            }
            var depth = 0
            for index in opening...last {
                try budget.consume()
                if code[index] == 40 {
                    depth += 1
                }
                if code[index] == 41 {
                    depth -= 1
                    if depth < 0 || depth == 0 && index < last {
                        return .none
                    }
                }
            }
            return depth == 0 ? .open(.function) : .none
        case "for":
            guard let rest, code[rest] == 36 else {
                return .none
            }
            var index = rest
            while index <= last {
                try budget.consume()
                let candidate = word(code, at: index)
                if index > 0, code[index - 1] == 9 || code[index - 1] == 32,
                    ["in", "to"].contains(candidate.value), candidate.end <= last
                {
                    return .open(.forLoop)
                }
                index = max(index + 1, candidate.end)
            }
            return .none
        case "while":
            return hasOperand ? .open(.whileLoop) : .none
        case "with":
            return hasOperand ? .open(.withBlock) : .none
        case "switch":
            return hasOperand ? .open(.switchBlock) : .none
        case "select":
            return hasOperand ? .none : .open(.selectBlock)
        case "do":
            return hasOperand ? .none : .open(.doLoop)
        case "case":
            guard let rest else {
                return .none
            }
            let operand = word(code, at: rest)
            if operand.value == "else" {
                return operand.end == last + 1 ? .branch(true) : .none
            }
            return .branch(false)
        case "until":
            return hasOperand ? .close(.doLoop) : .none
        case "next":
            return .close(.forLoop)
        case "endif":
            return hasOperand ? .none : .close(.conditional)
        case "endfunc":
            return hasOperand ? .none : .close(.function)
        case "wend":
            return hasOperand ? .none : .close(.whileLoop)
        case "endwith":
            return hasOperand ? .none : .close(.withBlock)
        case "endswitch":
            return hasOperand ? .none : .close(.switchBlock)
        case "endselect":
            return hasOperand ? .none : .close(.selectBlock)
        default:
            return .none
        }
    }

    /// 业务作用：仅完整 ASCII 标识符参与结构关键字比较，变量、属性或更长名称不冒充语句开端。
    /// 参数说明:
    /// - code: 已确认的逻辑语句。
    /// - position: 当前候选起点。
    /// 返回：有限候选的小写名称及真实结束位置，非标识符位置提供空名称。
    private static func word(_ code: [UInt8], at position: Int) -> (value: String, end: Int) {
        guard position < code.count, letter(code[position]) else {
            return ("", position)
        }
        var end = position
        while end < code.count, letter(code[end]) || (48...57).contains(code[end]) {
            end += 1
        }
        guard end - position <= 16 else {
            return ("", end)
        }
        return (String(decoding: code[position..<end], as: UTF8.self).lowercased(), end)
    }

    /// 业务作用：结构关键字保留完整 ASCII 名称边界，不把下划线后缀或名称片段当成独立关键字。
    /// 参数说明:
    /// - byte: 当前有限语句中的原字节。
    /// 返回：ASCII 字母或下划线时为真。
    private static func letter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }
}
