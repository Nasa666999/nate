// Copyright (c) 1998-2009 John Maddock
// Copyright 2008 Eric Niebler.
// 替换格式适配按 Boost Software License 1.0 分发，许可全文见 resources/licenses/Boost-LICENSE.txt。
import Foundation
import NateCore

struct ReplacementFormatter {
    let units: [UInt16]
    let hit: SearchHit
    let text: PieceTree
    var writer: ReplacementWriter
    var index = 0
    var haveConditional = false

    /// 业务作用：按 Boost 扩展格式扫描当前作用域，括号只限定条件分支边界，不隔离大小写状态。
    /// 参数说明:
    /// - depth: 当前格式递归深度。
    /// - budget: 整份计划共用的计算预算。
    /// 返回：停在当前右括号、条件冒号或格式末端，保留未消费的边界供调用方处理。
    mutating func scope(depth: Int, budget: inout ReplacementBudget) throws {
        guard depth < 128 else {
            throw NateError.message("替换格式嵌套超过 128 层。")
        }
        while index < units.count {
            try budget.checkpoint()
            let unit = units[index]
            index += 1
            switch unit {
            case 92:
                try escape(budget: &budget)
            case 40:
                let outer = haveConditional
                haveConditional = false
                try untilEnd(depth: depth, budget: &budget)
                haveConditional = outer
                if index < units.count {
                    index += 1
                }
            case 41:
                index -= 1
                return
            case 58 where haveConditional:
                index -= 1
                return
            case 63:
                try conditional(depth: depth, budget: &budget)
            case 36:
                try dollar(budget: &budget)
            default:
                try writer.put(unit, budget: &budget)
            }
        }
    }

    /// 业务作用：消费完整当前作用域，条件没有继续消费的冒号仍作为普通输出处理。
    /// 参数说明:
    /// - depth: 外层递归深度。
    /// - budget: 原计划计算预算。
    /// 返回：停在右括号或末端，未闭合左括号按基准接受至格式末尾。
    mutating func untilEnd(depth: Int, budget: inout ReplacementBudget) throws {
        while index < units.count {
            try scope(depth: depth + 1, budget: &budget)
            guard index < units.count, units[index] != 41 else {
                return
            }
            try writer.put(units[index], budget: &budget)
            index += 1
        }
    }

    /// 业务作用：按捕获是否参与执行条件格式，未选分支仍解析状态控制以保持基准的实际输出顺序。
    /// 参数说明:
    /// - depth: 条件所属的格式深度。
    /// - budget: 原计划共享预算。
    /// 返回：完成当前条件的两支处理，未知条件保持字面问号及后续内容。
    mutating func conditional(depth: Int, budget: inout ReplacementBudget) throws {
        guard index < units.count else {
            try writer.put(63, budget: &budget)
            return
        }
        let group: Int?
        if units[index] == 123 {
            let start = index
            index += 1
            if let number = try number(radix: 10, maximum: units.count, budget: &budget) {
                group = number
            }
            else {
                while index < units.count, units[index] != 125 {
                    try budget.checkpoint()
                    index += 1
                }
                group = hit.names[String(decoding: units[(start + 1)..<index], as: UTF16.self)]
            }
            guard group != nil, index < units.count, units[index] == 125 else {
                index = start
                try writer.put(63, budget: &budget)
                return
            }
            index += 1
        }
        else {
            group = try number(radix: 10, maximum: min(index + 2, units.count), budget: &budget)
        }
        guard let group else {
            try writer.put(63, budget: &budget)
            return
        }
        if hit.captures[group] != nil {
            haveConditional = true
            try scope(depth: depth + 1, budget: &budget)
            haveConditional = false
            if index < units.count, units[index] == 58 {
                index += 1
                let saved = writer.state
                writer.state = .none
                try untilEnd(depth: depth, budget: &budget)
                writer.state = saved
            }
        }
        else {
            let saved = writer.state
            writer.state = .none
            haveConditional = true
            try scope(depth: depth + 1, budget: &budget)
            haveConditional = false
            writer.state = saved
            if index < units.count, units[index] == 58 {
                index += 1
                try untilEnd(depth: depth, budget: &budget)
            }
        }
    }

    /// 业务作用：读取有界字符码或捕获编号，不把非 ASCII 数字解释为格式控制。
    /// 参数说明:
    /// - radix: 十进制、十六进制或八进制。
    /// - maximum: 允许消费的最后格式位置。
    /// - budget: 原计划共享预算。
    /// 返回：至少一位且未溢出的编号，否则为空；停在首个不属于该进制的单元。
    mutating func number(radix: Int, maximum: Int, budget: inout ReplacementBudget) throws -> Int? {
        let start = index
        var result = 0
        while index < maximum {
            try budget.checkpoint()
            let unit = units[index]
            let digit =
                unit >= 48 && unit <= 57
                ? Int(unit - 48)
                : unit >= 65 && unit <= 70
                    ? Int(unit - 65) + 10
                    : unit >= 97 && unit <= 102 ? Int(unit - 97) + 10 : radix
            guard digit < radix else {
                break
            }
            guard result <= (Int(Int32.max) - digit) / radix else {
                return nil
            }
            result = result * radix + digit
            index += 1
        }
        return index == start ? nil : result
    }

    /// 业务作用：按合法 UTF-8 分块读取被引用范围，避免大捕获或上下文绕过取消与内存门禁。
    /// 参数说明:
    /// - range: 原快照中的 UTF-16 捕获或上下文范围。
    /// - budget: 原计划共享预算。
    /// 返回：只将合法完整标量传给输出状态机，超过单次读取额度时在复制前失败。
    mutating func source(_ range: NSRange?, budget: inout ReplacementBudget) throws {
        guard let range else {
            return
        }
        guard let bytes = text.byteRange(range) else {
            throw NateError.message("替换引用不能无损映射到原文。")
        }
        guard bytes.count <= ReplacementBudget.itemLimit else {
            throw NateError.message("单次捕获或上下文读取超过 64 MiB。")
        }
        if writer.state == .none {
            return
        }
        var start = bytes.lower
        while start < bytes.upper {
            var end = min(start + 4096, bytes.upper)
            while !text.isBoundary(end) {
                end -= 1
            }
            try budget.reserve(end - start)
            try writer.write(text.text(in: ByteRange(start, end)), budget: &budget)
            start = end
        }
    }
}
