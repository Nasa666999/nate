import Foundation

extension RustLexing {
    /// 业务作用：单引号候选区分生命周期、字符和字节字符，合法结束符不能误变成后续结构。
    /// 参数说明:
    /// - asciiOnly: 字节字符只接受 ASCII，且不取得生命周期身份。
    /// 返回：候选按完整边界封存；非法内容保持独立词法错误类别。
    mutating func character(asciiOnly: Bool) throws {
        cursor += 1
        var lifetime = !asciiOnly && Self.identifierStart(byte(cursor))
        var valid = true
        var first = true
        var done = false
        while !done {
            try budget.consume()
            let c = byte(cursor), n = byte(cursor + 1)
            switch c {
            case 92:
                done = true
                if Self.validEscape(n) {
                    cursor += 2
                }
                else if n == 120 {
                    cursor += 2
                    valid = try numericEscape(digits: 2, stopAsSoonAsComplete: false)
                }
                else if !asciiOnly, n == 117 || n == 85 {
                    cursor += 2
                    valid = try unicodeEscape(long: n == 85, stopAsSoonAsComplete: false)
                }
                else {
                    valid = false
                }
            case 39:
                valid = !first
                done = true
            case 9, 10, 13, 0:
                valid = false
                done = true
            default:
                if asciiOnly, c >= 128 {
                    done = true
                    valid = false
                }
                else if !Self.identifierContinue(c), !first {
                    done = true
                }
                else {
                    cursor += 1
                }
            }
            first = false
        }
        if byte(cursor) == 39 {
            lifetime = false
        }
        else {
            valid = false
        }
        if lifetime {
            try paint(18)
        }
        else if valid {
            cursor += 1
            try paint(asciiOnly ? 23 : 15)
        }
        else {
            try paint(20)
        }
    }

    /// 业务作用：数值转义按请求位数识别，字符转义保留基准的完整连续十六进制扫描语义。
    /// 参数说明:
    /// - digits: 当前转义要求的确切十六进制位数。
    /// - stopAsSoonAsComplete: 字符串满足位数立即结束，字符候选继续识别紧邻十六进制。
    /// 返回：实际位数符合要求时为真，光标停在已确认数字之后。
    mutating func numericEscape(digits: Int, stopAsSoonAsComplete: Bool) throws -> Bool {
        var remaining = digits
        while Self.digit(byte(cursor), radix: 16) {
            try budget.consume()
            cursor += 1
            remaining -= 1
            if remaining == 0, stopAsSoonAsComplete {
                return true
            }
        }
        return remaining == 0
    }

    /// 业务作用：Unicode 字面转义保留固定宽度和花括号两种基准形式，不展开或改写原标量。
    /// 参数说明:
    /// - long: 大写 U 使用八位形式，小写 u 使用四位或花括号形式。
    /// - stopAsSoonAsComplete: 当前字符串或字符候选的数字停止规则。
    /// 返回：转义完整时为真，非法尾部交回外层词法分类。
    mutating func unicodeEscape(long: Bool, stopAsSoonAsComplete: Bool) throws -> Bool {
        if long || byte(cursor) != 123 {
            return try numericEscape(digits: long ? 8 : 4, stopAsSoonAsComplete: stopAsSoonAsComplete)
        }
        var count = 0
        repeat {
            try budget.consume()
            cursor += 1
            if !Self.digit(byte(cursor), radix: 16) {
                break
            }
            count += 1
        } while count <= 6
        if count > 0, byte(cursor) == 125 {
            cursor += 1
            return true
        }
        return false
    }
}
