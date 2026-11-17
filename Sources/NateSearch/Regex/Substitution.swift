// Copyright (c) 1998-2009 John Maddock
// Copyright 2008 Eric Niebler.
// 替换格式适配按 Boost Software License 1.0 分发，许可全文见 resources/licenses/Boost-LICENSE.txt。
import Foundation
import NateCore

enum Substitution {
    /// 业务作用：解释 Boost 扩展替换格式，分组、条件与大小写状态沿实际执行顺序共享。
    /// 参数说明:
    /// - format: 完整替换格式，UTF-8 输入上限为 1 MiB。
    /// - hit: 原快照的捕获、最后关闭捕获和逐轮上下文。
    /// - text: 不可变正文树，只读取实际引用的范围。
    /// - outputLimit: 单项和整份计划剩余输出额度中的较小值。
    /// - budget: 整份计划共用的计算和读取预算。
    /// - depth: 所属格式的初始嵌套深度。
    /// 返回：完整合法 UTF-8 输出；孤立代理项、取消及任何预算失败均不产生部分计划。
    static func expand(
        _ format: String,
        hit: SearchHit,
        text: PieceTree,
        outputLimit: Int,
        budget: inout ReplacementBudget,
        depth: Int = 0
    ) throws -> String {
        try budget.checkpoint(force: true)
        guard format.utf8.count <= ReplacementBudget.formatLimit else {
            throw NateError.message("替换格式超过 1 MiB。")
        }
        var formatter = ReplacementFormatter(
            units: Array(format.utf16),
            hit: hit,
            text: text,
            writer: ReplacementWriter(limit: outputLimit)
        )
        try formatter.scope(depth: depth, budget: &budget)
        return try formatter.writer.finish(budget: &budget)
    }
}

enum ReplacementCase {
    case copy, none, lower, upper, nextLower, nextUpper
}

struct ReplacementWriter {
    let limit: Int
    var state = ReplacementCase.copy
    var restore = ReplacementCase.copy
    var result = ""
    var byteCount = 0
    var buffer: [UInt8] = []
    var highSurrogate: UInt16?

    /// 业务作用：对完整合法片段采用有界直接追加，大小写转换仍按 UTF-16 单元执行。
    /// 参数说明:
    /// - text: 最多一个读取分块的合法原文。
    /// - budget: 原计划的共享预算。
    /// 返回：按当前状态写入片段，不跨片段重置单次大小写状态。
    mutating func write(_ text: String, budget: inout ReplacementBudget) throws {
        if state == .none {
            return
        }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            try budget.checkpoint()
            if state == .copy && highSurrogate == nil {
                try flush(budget: &budget)
                let remainder = String(decoding: units[index...], as: UTF16.self)
                try append(remainder, budget: &budget)
                return
            }
            try put(units[index], budget: &budget)
            index += 1
        }
    }

    /// 业务作用：按单个 UTF-16 单元推进大小写和代理项状态，禁止用替代字符掩盖非法输出。
    /// 参数说明:
    /// - unit: 格式或捕获中的原始单元。
    /// - budget: 整份计划预算。
    /// 返回：只有完整标量进入 UTF-8 缓冲区，等待中的高代理项不提前发布。
    mutating func put(_ unit: UInt16, budget: inout ReplacementBudget) throws {
        var unit = unit
        switch state {
        case .none:
            return
        case .nextLower:
            unit = mapped(unit, upper: false)
            state = restore
        case .nextUpper:
            unit = mapped(unit, upper: true)
            state = restore
        case .lower:
            unit = mapped(unit, upper: false)
        case .upper:
            unit = mapped(unit, upper: true)
        case .copy:
            break
        }
        let value: UInt32
        if let high = highSurrogate {
            guard (0xdc00...0xdfff).contains(unit) else {
                throw NateError.message("替换输出含孤立 UTF-16 代理项，未修改原文。")
            }
            value = 0x10000 + (UInt32(high) - 0xd800) * 1024 + UInt32(unit) - 0xdc00
            highSurrogate = nil
        }
        else if (0xd800...0xdbff).contains(unit) {
            highSurrogate = unit
            return
        }
        else {
            value = UInt32(unit)
        }
        guard let scalar = Unicode.Scalar(value) else {
            throw NateError.message("替换输出含孤立 UTF-16 代理项，未修改原文。")
        }
        let bytes = String(scalar).utf8
        guard bytes.count <= limit - byteCount else {
            throw NateError.message("替换输出超过单项 64 MiB 或总量 256 MiB 预算。")
        }
        buffer.append(contentsOf: bytes)
        byteCount += bytes.count
        if buffer.count >= 4096 {
            try flush(budget: &budget)
        }
    }

    /// 业务作用：大小写映射保持 Windows 正则的单元边界，不把一个单元扩成多个输出字符。
    /// 参数说明:
    /// - unit: 待映射的 UTF-16 单元。
    /// - upper: 是否使用大写映射。
    /// 返回：单单元映射；代理项或多单元扩展保留原值，系统非 ASCII 分类仍受平台规则约束。
    func mapped(_ unit: UInt16, upper: Bool) -> UInt16 {
        if upper, (97...122).contains(unit) {
            return unit - 32
        }
        if !upper, (65...90).contains(unit) {
            return unit + 32
        }
        guard unit >= 128, let scalar = Unicode.Scalar(unit) else {
            return unit
        }
        let value = upper ? String(scalar).uppercased() : String(scalar).lowercased()
        let mapped = Array(value.utf16)
        return mapped.count == 1 ? mapped[0] : unit
    }

    /// 业务作用：将已经确认合法的片段计入总输出，追加前完成剩余额度校验。
    /// 参数说明:
    /// - text: 合法 UTF-8 片段。
    /// - budget: 原计划共享预算。
    /// 返回：更新输出及精确 UTF-8 字节数，超限前不追加。
    mutating func append(_ text: String, budget: inout ReplacementBudget) throws {
        let count = text.utf8.count
        guard count <= limit - byteCount else {
            throw NateError.message("替换输出超过单项 64 MiB 或总量 256 MiB 预算。")
        }
        try budget.reserve(count)
        result += text
        byteCount += count
    }

    /// 业务作用：集中发布完整标量缓冲，避免每写入一个字符重算既有输出长度。
    /// 参数说明:
    /// - budget: 整份计划的共享预算。
    /// 返回：缓冲内容追加一次并释放已处理单元，额度或取消失败时停止。
    mutating func flush(budget: inout ReplacementBudget) throws {
        guard !buffer.isEmpty else {
            return
        }
        try budget.reserve(buffer.count)
        result += String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
    }

    /// 业务作用：完整格式结束后复验输出标量闭合，再交付可进入事务的正文。
    /// 参数说明:
    /// - budget: 原计划预算。
    /// 返回：合法完整替换文本；尾部孤立高代理项明确拒绝。
    mutating func finish(budget: inout ReplacementBudget) throws -> String {
        guard highSurrogate == nil else {
            throw NateError.message("替换输出含孤立 UTF-16 代理项，未修改原文。")
        }
        try flush(budget: &budget)
        try budget.checkpoint(force: true)
        return result
    }
}
