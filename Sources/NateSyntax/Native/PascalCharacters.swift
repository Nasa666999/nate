import Foundation

enum PascalCharacters {
    /// 业务作用：Pascal 标识符起点沿原字节规则解释，非 ASCII 字节不被额外拆成标点。
    /// 参数说明:
    /// - byte: 当前完整 UTF-8 原文中的一个字节。
    /// 返回：ASCII 字母、下划线或高位字节为真。
    static func wordStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }

    /// 业务作用：已开始的 Pascal 名称允许十进制数字续接，不沿显示段边缘提前分类关键字。
    /// 参数说明:
    /// - byte: 名称候选中的当前原字节。
    /// 返回：字母、数字、下划线或高位字节为真。
    static func word(_ byte: UInt8) -> Bool {
        wordStart(byte) || digit(byte)
    }

    /// 业务作用：数字起点只接受 ASCII 十进制数字，Unicode 数字保留名称语义。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：0 至 9 的原字节为真。
    static func digit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：十六进制及字符代码采用同一 ASCII 外观，不把其它字母混入数值范围。
    /// 参数说明:
    /// - byte: 当前候选原字节。
    /// 返回：ASCII 数字、A–F 或 a–f 时为真。
    static func hex(_ byte: UInt8) -> Bool {
        digit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    /// 业务作用：关键字只进行原生 ASCII 大小写折叠，Unicode 原字节和长度不变。
    /// 参数说明:
    /// - byte: 名称中的一个原字节。
    /// 返回：ASCII 大写转换为对应小写，其余原样保留。
    static func folded(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// 业务作用：Pascal 操作符保持明确原生集合，汇编中的同形字符由汇编状态单独解释。
    /// 参数说明:
    /// - byte: 当前尚未归入名称、数值、注释或字面的原字节。
    /// 返回：属于 Pascal 原生操作符集合时为真。
    static func operation(_ byte: UInt8) -> Bool {
        switch byte {
        case 35, 36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 64, 91, 93, 94, 123, 125:
            return true
        default:
            return false
        }
    }
}
