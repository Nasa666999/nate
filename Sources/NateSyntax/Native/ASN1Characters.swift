import Foundation

enum ASN1Characters {
    /// 业务作用：ASN.1 普通数值与 OID 数字只采用 ASCII 十进制数字，不把其它字形扩成数值。
    /// 参数说明:
    /// - value: 当前完整 Unicode 标量或有限边缘哨兵。
    /// 返回：ASCII 零至九时为真。
    static func digit(_ value: UInt32) -> Bool {
        (48...57).contains(value)
    }

    /// 业务作用：原生 ASN.1 名称由 ASCII 字母、数字和连字符组成，注释开端另按当前通道决定。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：该标量能够继续原生命名候选时为真。
    static func word(_ value: UInt32) -> Bool {
        value == 45 || digit(value) || (65...90).contains(value) || (97...122).contains(value)
    }
}
