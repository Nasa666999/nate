import Foundation

enum AutoItCharacters {
    /// 业务作用：AutoIt 的数值只使用原生 ASCII 数字，不把其它数字字形引入指数或十六进制通道。
    /// 参数说明:
    /// - value: 当前完整 Unicode 标量。
    /// 返回：属于原生十进制字符时为真。
    static func digit(_ value: UInt32) -> Bool {
        (48...57).contains(value)
    }

    /// 业务作用：原生名称字符限定 ASCII 字母、数字和下划线，Unicode 字形仍作为完整正文保留。
    /// 参数说明:
    /// - value: 当前完整 Unicode 标量。
    /// 返回：允许继续原生名称时为真。
    static func word(_ value: UInt32) -> Bool {
        digit(value) || (65...90).contains(value) || (97...122).contains(value) || value == 95
    }

    /// 业务作用：宏、预处理及变量前导字符只授予原生名称开端资格，不修改实际输入字节。
    /// 参数说明:
    /// - value: 当前完整 Unicode 标量或明确的原生 char 低八位。
    /// 返回：可以开启原生候选时为真。
    static func wordStart(_ value: UInt32) -> Bool {
        word(value) || [64, 35, 36, 46].contains(value)
    }

    /// 业务作用：操作符沿原实现的 char 低八位比较，不能因显示为 Unicode 而改变既定词法类别。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：低八位为原生操作符时为真，完整显示标量不被拆开。
    static func operation(_ value: UInt32) -> Bool {
        [43, 45, 42, 47, 38, 94, 61, 60, 62, 40, 41, 91, 93, 44].contains(value & 255)
    }

    /// 业务作用：资源查询只折叠原生 ASCII 大写，候选原字节不受地区和 Unicode 大小写扩展影响。
    /// 参数说明:
    /// - value: 当前原始 UTF-8 字节。
    /// 返回：ASCII 小写字节或原值。
    static func lower(_ value: UInt8) -> UInt8 {
        (65...90).contains(value) ? value + 32 : value
    }
}
