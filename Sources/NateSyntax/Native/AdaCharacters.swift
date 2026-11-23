import Foundation
import NateCore

enum AdaCharacters {
    /// 业务作用：Ada 的名称和数值只在原生分隔符处收束，Unicode 显示不额外取得标点资格。
    /// 参数说明:
    /// - value: 当前完整 Unicode 标量。
    /// 返回：原生 Ada 分隔符成员时为真。
    static func delimiter(_ value: UInt32) -> Bool {
        [38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 124].contains(value)
    }

    /// 业务作用：Ada 原生空白只包含 ASCII 空格和制表及物理控制空白，NUL 仍是正文字符。
    /// 参数说明:
    /// - value: 当前完整标量或显式边缘哨兵。
    /// 返回：原生空白成员时为真。
    static func space(_ value: UInt32) -> Bool {
        value == 32 || (9...13).contains(value)
    }

    /// 业务作用：名称及数字共享真实词法边界，不按显示上的 Unicode 空白拆分原文。
    /// 参数说明:
    /// - value: 当前完整标量。
    /// 返回：真实原生空白或分隔符时为真。
    static func separator(_ value: UInt32) -> Bool {
        space(value) || delimiter(value)
    }

    /// 业务作用：Ada 候选保留原生先对完整标量做 ASCII 小写、再转换 char 的顺序。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：对应低八位候选字节，原文及显示边界不改变。
    static func folded(_ value: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: (65...90).contains(value) ? value + 32 : value)
    }

    /// 业务作用：Ada 标识符拒绝空名称、前后及连续下划线和非 ASCII 字母数字，完整名称不截断比较。
    /// 参数说明:
    /// - bytes: 原生转换后的完整候选。
    /// - budget: 本次分类共同预算。
    /// 返回：符合原生标识符规则时为真；取消或超限时抛错。
    static func identifier(_ bytes: [UInt8], budget: inout ANSILexingBudget) throws -> Bool {
        guard let first = bytes.first, (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        var underscore = false
        for byte in bytes {
            try budget.consume()
            guard
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || byte == 95, byte != 95 || !underscore
            else {
                return false
            }
            underscore = byte == 95
        }
        return !underscore
    }
}
