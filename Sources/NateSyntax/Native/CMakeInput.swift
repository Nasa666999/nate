import Foundation
import NateCore

extension CMakeScanner {
    /// 业务作用：CMake 前后字节只能来自当前完整物理范围或同一固定正文，不把显示边缘当成 EOF。
    /// 参数说明:
    /// - position: 相对当前物理范围的原字节位置，可用于前两字节或下一字节读取。
    /// 返回：同源原字节或真实文档边缘的空格哨兵，越界或预算不足时拒绝。
    mutating func byte(at position: Int) throws -> UInt8 {
        try budget.consume()
        if position >= 0, position < bytes.count {
            return bytes[position]
        }
        guard let snapshot else {
            return 32
        }
        if position < 0 {
            guard position >= -2, base >= -position else {
                return 32
            }
        }
        else {
            guard position <= bytes.count + 1, base <= Int.max - position else {
                throw NateError.invalidRange
            }
        }
        return snapshot.text.byte(at: base + position) ?? 32
    }

    /// 业务作用：ColourTo 仅封闭尚未交付的顺序范围，原生前瞻已封闭的字符不得被后续迭代覆盖。
    /// 参数说明:
    /// - end: 包含在内的本物理范围字节末端。
    /// - style: 该完整范围的原生类别。
    /// 返回：暂存类别沿顺序前进，范围或预算不足时拒绝整份结果。
    mutating func colour(until end: Int, style: UInt8) throws {
        guard end >= -1, end < bytes.count, style <= 14 else {
            throw NateError.invalidRange
        }
        if end < emitted {
            return
        }
        for index in emitted...end {
            try budget.consume()
            styles[index] = style
        }
        emitted = end + 1
    }
}
