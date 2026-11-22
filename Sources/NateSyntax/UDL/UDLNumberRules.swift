import Foundation

struct UDLNumberRules {
    let groups: [[[UInt8]]]
    let ignoreCase: Bool
    let separator: UDLDecimalSeparator

    /// 业务作用：数值前后缀及额外字符保留原定义顺序，负号规则从相应完整候选独立形成。
    /// 参数说明:
    /// - definition: 当前固定 UDL 的完整数字配置。
    /// - budget: 本行所有规则共用的容量和执行资格。
    /// 返回：不执行正则和区域数值转换的原字节规则；准备超量时整体失败。
    init(definition: UDLDefinition, budget: UDLScanBudget) throws {
        let names = ["prefix1", "prefix2", "extras1", "extras2", "suffix1", "suffix2", "range"]
        var prepared: [[[UInt8]]] = []
        for name in names {
            var values: [[UInt8]] = []
            for value in definition.lists["Numbers, " + name] ?? [] {
                try budget.consume(value.utf8.count + 1)
                if !value.isEmpty {
                    values.append(Array(value.utf8))
                }
            }
            prepared.append(values)
        }
        for index in [0, 1, 3] {
            var values: [[UInt8]] = []
            for value in prepared[index] {
                try budget.consume(value.count + 1)
                values.append([45] + value)
            }
            prepared.append(values)
        }
        groups = prepared
        ignoreCase = definition.caseIgnored
        separator = definition.decimalSeparator
    }

    /// 业务作用：同一数值组按定义顺序匹配，不让较长候选覆盖用户明确配置的较早前后缀。
    /// 参数说明:
    /// - group: 数字规则组索引。
    /// - bytes: 当前完整物理行。
    /// - offset: 实际匹配起点。
    /// - budget: 数值扫描与其它语法共用的工作量和截止。
    /// 返回：首个完整匹配的原字节长度，不匹配时为空。
    func first(_ group: Int, in bytes: [UInt8], at offset: Int, budget: UDLScanBudget) throws -> Int? {
        for pattern in groups[group] {
            try budget.consume()
            guard pattern.count <= bytes.count - offset else {
                continue
            }
            var matched = true
            for index in pattern.indices {
                try budget.consume()
                if Self.fold(pattern[index], enabled: ignoreCase)
                    != Self.fold(bytes[offset + index], enabled: ignoreCase)
                {
                    matched = false
                    break
                }
            }
            if matched {
                return pattern.count
            }
        }
        return nil
    }

    /// 业务作用：数字配置的点号和逗号按明确规则识别，不随操作系统区域设置转换。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：当前定义允许其作为小数分隔符时为真。
    func isDecimal(_ byte: UInt8) -> Bool {
        byte == 46 && separator != .comma || byte == 44 && separator != .dot
    }

    /// 业务作用：数值结束证据来自当前允许的上下文和字面组，注释内部不能借未启用的运算符截取数字。
    /// 参数说明:
    /// - definition: 当前固定 UDL。
    /// - comments: 已解析的注释起止与续行候选。
    /// - delimiters: 已解析的八组分隔符候选。
    /// - nesting: 当前上下文明确允许的嵌套组。
    /// - contextEnds: 当前上下文本身的完整闭合候选。
    /// - budget: 本行共享工作量和执行资格。
    /// 返回：兼容数字判定所用的终止外观首字节集合，不包含虚构的文件末尾结束符。
    func terminators(
        definition: UDLDefinition,
        comments: [Int: [String]],
        delimiters: [Int: [String]],
        nesting: UInt32,
        contextEnds: [String],
        budget: UDLScanBudget
    ) throws -> Set<UInt8> {
        var patterns = contextEnds
        if nesting & 0x100 != 0 {
            patterns += (comments[3] ?? []) + (comments[4] ?? [])
        }
        if nesting & 0x200 != 0 {
            patterns += (comments[0] ?? []) + (comments[1] ?? []) + (comments[2] ?? [])
        }
        if nesting & 0x1000000 != 0 {
            patterns += definition.lists["Operators1"] ?? []
        }
        for group in 0..<8 where nesting & (1 << group) != 0 {
            patterns += delimiters[group * 3 + 2] ?? []
        }
        if nesting == UInt32.max {
            for name in ["Folders in code1, open", "Folders in code1, middle", "Folders in code1, close"] {
                patterns += definition.lists[name] ?? []
            }
        }
        var ends: Set<UInt8> = []
        for pattern in patterns {
            try budget.consume()
            guard let byte = pattern.utf8.first, byte != 0 else {
                continue
            }
            ends.insert(byte)
            if ignoreCase, (65...90).contains(byte) {
                ends.insert(byte + 32)
            }
            else if ignoreCase, (97...122).contains(byte) {
                ends.insert(byte - 32)
            }
        }
        return ends
    }

    /// 业务作用：数字部分只接受 ASCII 十进制位，不把 Unicode 数字外观隐式转换为数值。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：属于零至九时为真。
    static func digit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：未成立的连续候选保持整体字面身份，不在内部标点之后重试并着色尾部数字。
    /// 参数说明:
    /// - bytes: 当前完整物理行。
    /// - start: 本次未成立候选的开端。
    /// - ends: 当前允许的结束外观。
    /// - budget: 本行共同的工作量和截止。
    /// 返回：下一个真实空白或启用结束外观的位置，缺少时为当前行末。
    static func failedEnd(in bytes: [UInt8], from start: Int, ends: Set<UInt8>, budget: UDLScanBudget) throws
        -> Int
    {
        var end = start
        while end < bytes.count {
            try budget.consume()
            let byte = bytes[end]
            if byte > 0 && byte < 33 || ends.contains(byte) {
                break
            }
            end += 1
        }
        return end
    }

    /// 业务作用：数字候选的大小写规则只折叠 ASCII，保留多字节前后缀的精确原字节长度。
    /// 参数说明:
    /// - byte: 当前候选或原文字节。
    /// - enabled: 是否忽略 ASCII 大小写。
    /// 返回：需要时折叠 ASCII 大写，其它字节逐值保留。
    private static func fold(_ byte: UInt8, enabled: Bool) -> UInt8 {
        enabled && (65...90).contains(byte) ? byte + 32 : byte
    }
}
