// Copyright (c) 1998-2009 John Maddock
// Copyright 2008 Eric Niebler.
// 替换格式适配按 Boost Software License 1.0 分发，许可全文见 resources/licenses/Boost-LICENSE.txt。
import Foundation
import NateCore

extension ReplacementFormatter {
    /// 业务作用：区分单数字反向引用、八进制字符码、十六进制和大小写格式控制。
    /// 参数说明:
    /// - budget: 原计划共享预算。
    /// 返回：消费反斜杠后的完整控制；残缺或未知写法按基准保留相应字面内容。
    mutating func escape(budget: inout ReplacementBudget) throws {
        guard index < units.count else {
            try writer.put(92, budget: &budget)
            return
        }
        let token = units[index]
        index += 1
        let simple: [UInt16: UInt16] = [97: 7, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11, 101: 27]
        if let value = simple[token] {
            try writer.put(value, budget: &budget)
            return
        }
        switch token {
        case 120:
            let origin = index - 1
            if index < units.count, units[index] == 123 {
                index += 1
                if let value = try number(radix: 16, maximum: units.count, budget: &budget) {
                    if index < units.count, units[index] == 125 {
                        index += 1
                        try writer.put(UInt16(truncatingIfNeeded: value), budget: &budget)
                        return
                    }
                    index = origin + 1
                }
                else {
                    try writer.put(120, budget: &budget)
                    try writer.put(123, budget: &budget)
                    return
                }
            }
            else if let value = try number(radix: 16, maximum: min(index + 2, units.count), budget: &budget) {
                try writer.put(UInt16(truncatingIfNeeded: value), budget: &budget)
                return
            }
            try writer.put(120, budget: &budget)
        case 99:
            let value = index < units.count ? units[index] % 32 : 99
            if index < units.count {
                index += 1
            }
            try writer.put(value, budget: &budget)
        case 108:
            writer.restore = writer.state
            writer.state = .nextLower
        case 117:
            writer.restore = writer.state
            writer.state = .nextUpper
        case 76:
            writer.state = .lower
        case 85:
            writer.state = .upper
        case 69:
            writer.state = .copy
        case 49...57:
            try source(hit.captures[Int(token - 48)], budget: &budget)
        case 48:
            index -= 1
            let value = try number(radix: 8, maximum: min(index + 4, units.count), budget: &budget) ?? 0
            try writer.put(UInt16(truncatingIfNeeded: value), budget: &budget)
        default:
            try writer.put(token, budget: &budget)
        }
    }

    /// 业务作用：解析捕获、逐轮前后文及 Perl 格式别名，保留未知美元表达式。
    /// 参数说明:
    /// - budget: 原计划共享预算。
    /// 返回：实际引用只读取原快照；未参与或未知命名捕获产生空输出。
    mutating func dollar(budget: inout ReplacementBudget) throws {
        guard index < units.count else {
            try writer.put(36, budget: &budget)
            return
        }
        let start = index
        let token = units[index]
        index += 1
        switch token {
        case 38:
            try source(hit.captures[0], budget: &budget)
        case 96:
            try source(prefix(), budget: &budget)
        case 39:
            try source(suffix(), budget: &budget)
        case 36:
            try writer.put(36, budget: &budget)
        case 43:
            if index < units.count, units[index] == 123 {
                let brace = index
                index += 1
                let nameStart = index
                while index < units.count, units[index] != 125 {
                    try budget.checkpoint()
                    index += 1
                }
                if index < units.count {
                    let name = String(decoding: units[nameStart..<index], as: UTF16.self)
                    index += 1
                    if let group = hit.names[name] {
                        try source(hit.captures[group], budget: &budget)
                    }
                    return
                }
                index = brace
            }
            try source(hit.captures[max(1, hit.captureCount)], budget: &budget)
        default:
            let braced = token == 123
            index = braced ? start + 1 : start
            if let group = try number(radix: 10, maximum: units.count, budget: &budget),
                !braced || index < units.count && units[index] == 125
            {
                if braced {
                    index += 1
                }
                try source(hit.captures[group], budget: &budget)
                return
            }
            if try verb(braced: braced, budget: &budget) {
                return
            }
            index = start
            try writer.put(36, budget: &budget)
        }
    }

    /// 业务作用：将上下文和最后捕获别名解析为原有引用，不重新推断捕获参与顺序。
    /// 参数说明:
    /// - braced: 是否要求完整右花括号。
    /// - budget: 原计划共享预算。
    /// 返回：已识别并消费别名时为真，其余由美元字面路径继续处理。
    mutating func verb(braced: Bool, budget: inout ReplacementBudget) throws -> Bool {
        if braced, index < units.count, units[index] == 94 {
            index += 1
        }
        for name in ["MATCH", "PREMATCH", "POSTMATCH", "LAST_PAREN_MATCH", "LAST_SUBMATCH_RESULT", "^N"] {
            let expected = Array(name.utf16)
            let end = index + expected.count
            guard end <= units.count, units[index..<end].elementsEqual(expected),
                !braced || end < units.count && units[end] == 125
            else {
                continue
            }
            index = end + (braced ? 1 : 0)
            let range: NSRange?
            switch name {
            case "MATCH": range = hit.captures[0]
            case "PREMATCH": range = prefix()
            case "POSTMATCH": range = suffix()
            case "LAST_PAREN_MATCH": range = hit.captures[max(1, hit.captureCount)]
            default:
                if let group = hit.lastClosedCapture {
                    range = hit.captures[group]
                }
                else {
                    range = nil
                }
            }
            try source(range, budget: &budget)
            return true
        }
        return false
    }

    /// 业务作用：取得本轮真正起点至完整命中之前的原文范围。
    /// 参数说明: 无。
    /// 返回：已有逐轮证据，或调用方未提供上下文时的完整正文前缀。
    func prefix() -> NSRange {
        hit.context?.prefix
            ?? NSRange(
                location: 0,
                length: hit.utf16Range.location
            )
    }

    /// 业务作用：取得完整命中之后至本轮目标末端的原文范围。
    /// 参数说明: 无。
    /// 返回：已有逐轮证据，或调用方未提供上下文时的完整正文后缀。
    func suffix() -> NSRange {
        let end = hit.utf16Range.location + hit.utf16Range.length
        return hit.context?.suffix
            ?? NSRange(
                location: end,
                length: text.utf16Count - end
            )
    }
}
