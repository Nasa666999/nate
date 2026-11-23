import Foundation
import NateCore

enum AdaNumbers {
    /// 业务作用：Ada 数值按原生十进制或二至十六进制、下划线和指数规则取得完整有效或非法类别。
    /// 参数说明:
    /// - bytes: 不含真实分隔符的完整原生候选，有限 EOF 的原生哨兵按实际输入保留。
    /// - budget: 数值收集与验证共用的分类预算。
    /// 返回：完整候选合法时为真；取消或超限时抛错，不发布部分数值。
    static func valid(_ bytes: [UInt8], budget: inout ANSILexingBudget) throws -> Bool {
        guard !bytes.isEmpty else {
            return false
        }
        var based = false
        for byte in bytes {
            try budget.consume()
            if byte == 35 {
                based = true
                break
            }
        }
        var index = 0
        var dot = false
        if based {
            guard try base(bytes, index: &index, dot: &dot, budget: &budget) else {
                return false
            }
        }
        else {
            guard try decimal(bytes, index: &index, dot: &dot, budget: &budget) else {
                return false
            }
        }
        return try exponent(bytes, index: index, dot: dot, budget: &budget)
    }

    /// 业务作用：十进制尾数只允许数字之间的单个下划线和一个点，不把缺少右侧数字的点当成完整数值。
    /// 参数说明:
    /// - bytes: 当前完整候选。
    /// - index: 尾数起点及完成后的指数边界。
    /// - dot: 当前候选是否已含小数点。
    /// - budget: 共同分类预算。
    /// 返回：尾数以数字结束时为真，非法尾数为假；失去预算时抛错。
    private static func decimal(
        _ bytes: [UInt8],
        index: inout Int,
        dot: inout Bool,
        budget: inout ANSILexingBudget
    ) throws -> Bool {
        var special = false
        while index < bytes.count {
            try budget.consume()
            let byte = bytes[index]
            if byte == 95 {
                guard special else {
                    return false
                }
                special = false
            }
            else if byte == 46 {
                guard special, !dot else {
                    return false
                }
                special = false
                dot = true
            }
            else if (48...57).contains(byte) {
                special = true
            }
            else {
                break
            }
            index += 1
        }
        return special
    }

    /// 业务作用：基数及包围的尾数共同验证，超大基数在乘法前拒绝，不让算术溢出改变类别。
    /// 参数说明:
    /// - bytes: 当前完整候选。
    /// - index: 基数起点及闭合井号后的边界。
    /// - dot: 尾数是否已含小数点。
    /// - budget: 共同分类预算。
    /// 返回：基数在二至十六且尾数完整闭合时为真，非法形式为假；失去预算时抛错。
    private static func base(
        _ bytes: [UInt8],
        index: inout Int,
        dot: inout Bool,
        budget: inout ANSILexingBudget
    ) throws -> Bool {
        var base = 0
        var special = false
        while index < bytes.count {
            try budget.consume()
            let byte = bytes[index]
            if byte == 95 {
                guard special else {
                    return false
                }
                special = false
            }
            else if (48...57).contains(byte) {
                guard base <= 1, base * 10 + Int(byte - 48) <= 16 else {
                    return false
                }
                base = base * 10 + Int(byte - 48)
                special = true
            }
            else if byte == 35 && special {
                break
            }
            else {
                return false
            }
            index += 1
        }
        guard base >= 2, index < bytes.count else {
            return false
        }
        index += 1
        special = false
        while index < bytes.count {
            try budget.consume()
            let byte = AdaCharacters.folded(UInt32(bytes[index]))
            if byte == 95 {
                guard special else {
                    return false
                }
                special = false
            }
            else if byte == 46 {
                guard special, !dot else {
                    return false
                }
                special = false
                dot = true
            }
            else if (48...57).contains(byte) || (97...102).contains(byte) {
                let value = (48...57).contains(byte) ? Int(byte - 48) : Int(byte - 97) + 10
                guard value < base else {
                    return false
                }
                special = true
            }
            else if byte == 35 && special {
                index += 1
                return true
            }
            else {
                return false
            }
            index += 1
        }
        return false
    }

    /// 业务作用：指数只接受完整十进制整数，负指数仅属于已经含点的尾数。
    /// 参数说明:
    /// - bytes: 当前完整候选。
    /// - index: 尾数完成后的指数起点。
    /// - dot: 尾数是否含真实小数点。
    /// - budget: 共同分类预算。
    /// 返回：没有指数或指数完整合法时为真，其余为假；失去预算时抛错。
    private static func exponent(
        _ bytes: [UInt8],
        index: Int,
        dot: Bool,
        budget: inout ANSILexingBudget
    ) throws -> Bool {
        if index == bytes.count {
            return true
        }
        guard bytes[index] == 69 || bytes[index] == 101 else {
            return false
        }
        var index = index + 1
        guard index < bytes.count else {
            return false
        }
        if bytes[index] == 43 || bytes[index] == 45 && dot {
            index += 1
        }
        guard index < bytes.count else {
            return false
        }
        var special = false
        for byte in bytes[index...] {
            try budget.consume()
            if byte == 95 {
                guard special else {
                    return false
                }
                special = false
            }
            else if (48...57).contains(byte) {
                special = true
            }
            else {
                return false
            }
        }
        return special
    }
}
