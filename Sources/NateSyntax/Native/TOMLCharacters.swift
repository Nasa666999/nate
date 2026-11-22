import Foundation

extension TOMLScanner {
    /// 业务作用：TOML 原生名称与数值外观采用固定 ASCII 标识字符，不随系统区域改变。
    /// 参数说明:
    /// - scalar: 当前完整 Unicode 标量。
    /// 返回：ASCII 字母、数字或下划线时为真。
    static func identifier(_ scalar: UInt32) -> Bool {
        scalar >= 48 && scalar <= 57 || scalar >= 65 && scalar <= 90
            || scalar >= 97 && scalar <= 122 || scalar == 95
    }

    /// 业务作用：数值继续条件保留原生标识后缀、指数符号和非连续点号外观。
    /// 参数说明:
    /// - previous: 实际前一个标量。
    /// - current: 当前完整标量。
    /// - next: 同源后继标量。
    /// 返回：当前标量可以继续原生数值外观时为真。
    static func decimal(_ previous: UInt32, _ current: UInt32, _ next: UInt32) -> Bool {
        identifier(current) || (current == 43 || current == 45) && (previous == 101 || previous == 69)
            || current == 46 && next != 46
    }

    /// 业务作用：日期时间类别只按原生分隔符及后继数字外观决定，不校验日期值。
    /// 参数说明:
    /// - current: 当前完整标量。
    /// - next: 同源后继标量。
    /// 返回：当前标量采用日期时间继续规则时为真。
    static func isoDate(_ current: UInt32, _ next: UInt32) -> Bool {
        [43, 45, 58, 46].contains(current) && next >= 48 && next <= 57
            || current == 32 && (next == 43 || next == 45 || next >= 48 && next <= 57)
    }

    /// 业务作用：TOML 原生空白只采用 ASCII 范围，NUL 与 Unicode 分隔符保留原文身份。
    /// 参数说明:
    /// - scalar: 当前完整标量。
    /// 返回：ASCII 空格或水平及垂直空白范围时为真。
    static func space(_ scalar: UInt32) -> Bool {
        scalar == 32 || scalar >= 9 && scalar <= 13
    }

    /// 业务作用：未引用键只接纳原生 ASCII 标识字符和连字符。
    /// 参数说明:
    /// - scalar: 当前完整标量。
    /// 返回：当前标量可继续未引用键时为真。
    static func unquoted(_ scalar: UInt32) -> Bool {
        identifier(scalar) || scalar == 45
    }

    /// 业务作用：转义后继按固定十六进制外观着色，非法后继回到外层字面继续解释。
    /// 参数说明:
    /// - scalar: 当前完整标量。
    /// 返回：ASCII 十六进制字符时为真。
    static func hex(_ scalar: UInt32) -> Bool {
        scalar >= 48 && scalar <= 57 || scalar >= 65 && scalar <= 70
            || scalar >= 97 && scalar <= 102
    }
}
