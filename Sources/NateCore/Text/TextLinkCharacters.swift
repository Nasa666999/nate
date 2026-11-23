import Foundation

enum TextLinkCharacters {
    /// 业务作用：URI 首字符采用 ASCII 字母，避免相似 Unicode 字符取得协议匹配资格。
    /// 参数说明:
    /// - value: 原文中的完整 Unicode 标量值。
    /// 返回：标量为 ASCII 大写或小写字母时为真。
    static func isLetter(_ value: UInt32) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }

    /// 业务作用：协议字面匹配只忽略 ASCII 大小写，不改变正文或 Unicode 规范形态。
    /// 参数说明:
    /// - value: 原文或已验证协议中的完整标量值。
    /// 返回：ASCII 大写字母对应的小写值，其余标量保持原样。
    static func folded(_ value: UInt32) -> UInt32 {
        (65...90).contains(value) ? value + 32 : value
    }

    /// 业务作用：紧邻 ASCII 名称内部不切出链接，标点与非 ASCII 前导仍提供明确开始边界。
    /// 参数说明:
    /// - value: 候选协议之前的原文标量。
    /// 返回：标量不是 ASCII 字母、数字或下划线时允许协议开始。
    static func isSchemeDelimiter(_ value: UInt32) -> Bool {
        !isLetter(value) && !(48...57).contains(value) && value != 95
    }

    /// 业务作用：正文、查询及片段采用同一字面终止规则，控制字符与已定义的空白不能进入普通 URL 部分。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：可属于普通 URL 部分时为真；引号、结构界定符及查询起点由扫描状态另行处理。
    static func isText(_ value: UInt32) -> Bool {
        guard value > 32 else {
            return false
        }
        switch value {
        case 0x00A0, 0x2002...0x200B, 0x202F, 0x205F, 0x3000, 0xFEFF,
            34, 35, 60, 62, 123, 125, 63, 127:
            return false
        default:
            return true
        }
    }

    /// 业务作用：查询值只在明确分隔符之后进入配对引用状态，普通路径中的引号不改变扫描权限。
    /// 参数说明:
    /// - value: 查询中的原文标量。
    /// 返回：标量为 &、+、= 或分号时为真。
    static func isQueryDelimiter(_ value: UInt32) -> Bool {
        [38, 43, 61, 59].contains(value)
    }
}
