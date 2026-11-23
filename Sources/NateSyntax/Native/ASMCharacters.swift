import Foundation

enum ASMCharacters {
    /// 业务作用：汇编名称边界使用原生 ASCII 字母与数字规则，不把显示用 Unicode 标量额外解释为指令。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：ASCII 字母或十进制数字时为真。
    static func alphanumeric(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
    }

    /// 业务作用：名称后继保留点号、下划线及问号，开端专用标记不自动取得后继资格。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：原生名称后继字符时为真。
    static func word(_ value: UInt8) -> Bool {
        alphanumeric(value) || [46, 95, 63].contains(value)
    }

    /// 业务作用：汇编名称开端允许原生宏与局部名称标记，数字优先由扫描器取得数值身份。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：原生名称开端字符时为真。
    static func wordStart(_ value: UInt8) -> Bool {
        alphanumeric(value) || [95, 46, 37, 64, 36, 63].contains(value)
    }

    /// 业务作用：数值外观只从十进制数字或点后数字开始，不在词法层验证汇编数值类型。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：ASCII 十进制数字时为真。
    static func digit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
    }

    /// 业务作用：原生有序词表和候选共同进行 ASCII 小写转换，扩展字节保持原值。
    /// 参数说明:
    /// - value: 原词表或名称候选的原字节。
    /// 返回：ASCII 大写转为对应小写，其它原字节不变。
    static func folded(_ value: UInt8) -> UInt8 {
        (65...90).contains(value) ? value + 32 : value
    }

    /// 业务作用：汇编操作符保持原生优先级，点号保留给名称及数字。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：原生操作符集合成员时为真。
    static func operation(_ value: UInt8) -> Bool {
        [42, 47, 45, 43, 40, 41, 61, 94, 91, 93, 60, 38, 62, 44, 124, 126, 37, 58].contains(value)
    }
}
