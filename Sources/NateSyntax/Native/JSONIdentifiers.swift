import Foundation
import NateCore

extension JSONLexing {
    /// 业务作用：完整验证 JSON5 非引号属性名，转义后的码点也必须满足对应位置的固定规则。
    /// 参数说明:
    /// - candidate: 结构和空白之间的完整属性名原字节。
    /// 返回：所有标量及 Unicode 转义合法时为真；缺少固定资源或预算失败抛错。
    mutating func identifier(_ candidate: ArraySlice<UInt8>) throws -> Bool {
        var position = candidate.startIndex
        var first = true
        while position < candidate.endIndex {
            try budget.consume()
            let scalar: UInt32
            if candidate[position] == 92 {
                guard position + 5 < candidate.endIndex, candidate[position + 1] == 117 else {
                    return false
                }
                let digits = candidate[(position + 2)..<(position + 6)]
                guard digits.allSatisfy(JSONNumbers.hexadecimal),
                    let value = UInt32(String(decoding: digits, as: UTF8.self), radix: 16),
                    !(0xd800...0xdfff).contains(value)
                else {
                    return false
                }
                scalar = value
                position += 6
            }
            else {
                let width = scalarWidth(at: position)
                scalar = scalarValue(at: position)
                position += width
            }
            if scalar < 128 {
                guard
                    scalar == 36 || scalar == 95 || (65...90).contains(scalar)
                        || (97...122).contains(scalar) || (!first && (48...57).contains(scalar))
                else {
                    return false
                }
            }
            else {
                // 平台 Unicode 数据不能替代语言资源，避免同一原文在不同系统得到不同名称边界。
                guard let rules else {
                    throw NateError.message("JSON5 高亮暂停：缺少固定 Unicode 标识符资源。")
                }
                guard rules.contains(scalar, first: first) else {
                    return false
                }
            }
            first = false
        }
        return !first
    }
}
