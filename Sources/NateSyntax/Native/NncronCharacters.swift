import Foundation

enum NncronCharacters {
    /// 业务作用：nnCron 名称只接受原生 ASCII 字母开端，扩展文本仍按原字节保留。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：ASCII 大写或小写字母时为真。
    static func letter(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }

    /// 业务作用：nnCron 数值外观仅延续十进制数字，不把点号或符号纳入同一数字。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：ASCII 十进制数字时为真。
    static func digit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
    }

    /// 业务作用：nnCron 已开始的名称保留路径、扩展名及 Forth 风格标记，不借 Unicode 名称规则扩展。
    /// 参数说明:
    /// - value: 当前真实原字节。
    /// 返回：原生名称后继字符时为真。
    static func word(_ value: UInt8) -> Bool {
        letter(value) || digit(value) || [95, 45, 47, 36, 46, 60, 62, 64].contains(value)
    }
}
