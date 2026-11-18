import Foundation

enum IntegerLineComparison {
    /// 业务作用：按带符号 ASCII 整数片段比较原键，任意长数字不经过有界整数转换。
    /// 参数说明:
    /// - a: 左侧 UTF-16 原始键。
    /// - b: 右侧 UTF-16 原始键。
    /// - budget: 本轮完整排序的共享资格和时间。
    /// 返回：负、零、正表示原序比较；同数值的更多前导零优先，负零在非负零之前。
    static func compare(_ a: [UInt16], _ b: [UInt16], budget: LineSortBudget) throws -> Int {
        var i = 0, j = 0
        while i < a.count, j < b.count {
            try budget.check()
            let an = digit(a[i]) || a[i] == 45 && i + 1 < a.count && digit(a[i + 1])
            let bn = digit(b[j]) || b[j] == 45 && j + 1 < b.count && digit(b[j + 1])
            if an != bn {
                let result = Int(a[i]) - Int(b[j])
                i += 1
                j += 1
                if result != 0 {
                    return result
                }
            }
            else if an {
                let negative = a[i] == 45
                if negative != (b[j] == 45) {
                    return negative ? -1 : 1
                }
                if negative {
                    i += 1
                    j += 1
                }
                let ae = try endOfDigits(a, at: i, budget: budget)
                let be = try endOfDigits(b, at: j, budget: budget)
                let originalI = i, originalJ = j
                while i < ae, a[i] == 48 {
                    if i & 1023 == 0 {
                        try budget.check()
                    }
                    i += 1
                }
                while j < be, b[j] == 48 {
                    if j & 1023 == 0 {
                        try budget.check()
                    }
                    j += 1
                }
                let zerosA = i - originalI, zerosB = j - originalJ
                let sign = negative ? -1 : 1
                if ae - i != be - j {
                    return (ae - i < be - j ? -1 : 1) * sign
                }
                let result = try lexical(a, i..<ae, b, j..<be, budget: budget)
                if result != 0 {
                    return result * sign
                }
                if zerosA != zerosB {
                    return zerosA > zerosB ? -1 : 1
                }
                i = ae
                j = be
            }
            else {
                if a[i] == 45 {
                    i += 1
                }
                if b[j] == 45 {
                    j += 1
                }
                let ae = try endOfText(a, at: i, budget: budget)
                let be = try endOfText(b, at: j, budget: budget)
                let result = try lexical(a, i..<ae, b, j..<be, budget: budget)
                if result != 0 {
                    return result
                }
                i = ae
                j = be
            }
        }
        return try lexical(a, i..<a.count, b, j..<b.count, budget: budget)
    }

    /// 业务作用：字符序按 UTF-16 原码元比较，不把规范等价或补充平面字符改为另一种顺序。
    /// 参数说明:
    /// - a: 左侧完整码元。
    /// - ar: 左侧参与比较的有效范围。
    /// - b: 右侧完整码元。
    /// - br: 右侧参与比较的有效范围。
    /// - budget: 逐段比较使用的共同预算。
    /// 返回：原始序的三态比较，长公共前缀仍定期检查取消。
    static func lexical(
        _ a: [UInt16],
        _ ar: Range<Int>,
        _ b: [UInt16],
        _ br: Range<Int>,
        budget: LineSortBudget
    ) throws -> Int {
        for offset in 0..<min(ar.count, br.count) {
            if offset & 1023 == 0 {
                try budget.check()
            }
            let av = a[ar.lowerBound + offset], bv = b[br.lowerBound + offset]
            if av != bv {
                return av < bv ? -1 : 1
            }
        }
        return ar.count == br.count ? 0 : ar.count < br.count ? -1 : 1
    }

    /// 业务作用：整数片段只解释 ASCII 数字，避免不同语言的数字字形被隐式归为同一个值。
    /// 参数说明:
    /// - value: 原始 UTF-16 码元。
    /// 返回：属于十进制 ASCII 数字时为真。
    private static func digit(_ value: UInt16) -> Bool {
        value >= 48 && value <= 57
    }

    /// 业务作用：完整定位数字片段终点，超长数字不能只比较一个机器整数前缀。
    /// 参数说明:
    /// - units: 原始键。
    /// - start: 已确认的数字起点。
    /// - budget: 本轮共享执行预算。
    /// 返回：最后一位数字之后的位置，取消时不提供不完整片段。
    private static func endOfDigits(_ units: [UInt16], at start: Int, budget: LineSortBudget) throws -> Int {
        var end = start
        while end < units.count, digit(units[end]) {
            if end & 1023 == 0 {
                try budget.check()
            }
            end += 1
        }
        return end
    }

    /// 业务作用：整数排序的文本片段在下一数字或负号之前结束，独立负号继续作为片段分界。
    /// 参数说明:
    /// - units: 原始键。
    /// - start: 文本片段起点。
    /// - budget: 本轮共享执行预算。
    /// 返回：下一片段起点或键末尾。
    private static func endOfText(_ units: [UInt16], at start: Int, budget: LineSortBudget) throws -> Int {
        var end = start
        while end < units.count, !digit(units[end]), units[end] != 45 {
            if end & 1023 == 0 {
                try budget.check()
            }
            end += 1
        }
        return end
    }
}
