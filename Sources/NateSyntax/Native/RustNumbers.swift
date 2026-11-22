import Foundation

extension RustLexing {
    /// 业务作用：整数与浮点候选沿固定前缀、指数和后缀读取，方法调用与范围符号不被吞成小数。
    /// 参数说明: 无。
    /// 返回：完整数值或独立词法错误类别；不把呈现识别作为数值有效性证明。
    mutating func number() throws {
        var radix = 10
        var invalid = false
        if byte(cursor) == 48 {
            switch byte(cursor + 1) {
            case 120: radix = 16
            case 98: radix = 2
            case 111: radix = 8
            default: break
            }
            if radix != 10 {
                cursor += 2
            }
        }
        invalid = try !digits(radix: radix)
        let c = byte(cursor)
        if c == 117 || c == 105 {
            cursor += 1
            invalid = try !suffix(["8", "16", "32", "64", "128", "size"]) || invalid
        }
        else if !invalid {
            if c == 46, !Self.identifierStart(byte(cursor + 1)), byte(cursor + 1) != 46 {
                invalid = radix != 10
                cursor += 1
                _ = try digits(radix: 10)
            }
            if byte(cursor) == 101 || byte(cursor) == 69 {
                invalid = invalid || radix != 10
                cursor += 1
                if byte(cursor) == 45 || byte(cursor) == 43 {
                    cursor += 1
                }
                invalid = try !digits(radix: 10) || invalid
            }
            if byte(cursor) == 102 {
                invalid = invalid || radix != 10
                cursor += 1
                invalid = try !suffix(["32", "64"]) || invalid
            }
        }
        try paint(invalid ? 20 : 5)
    }

    /// 业务作用：后缀只消费真实匹配的固定原字节，未知后继不自动转换为合法类型。
    /// 参数说明:
    /// - values: 当前数值类别允许的有序后缀。
    /// 返回：首个完整匹配推进光标，缺少匹配时保留原后继。
    mutating func suffix(_ values: [String]) throws -> Bool {
        for value in values {
            var matches = true
            for (index, expected) in value.utf8.enumerated() {
                try budget.consume()
                if byte(cursor + index) != expected {
                    matches = false
                    break
                }
            }
            if matches {
                cursor += value.utf8.count
                return true
            }
        }
        return false
    }

    /// 业务作用：数字段允许基准中的下划线位置，后缀及指数共享相同前进预算。
    /// 参数说明:
    /// - radix: 当前二、八、十或十六进制。
    /// 返回：至少消费一个数字或下划线时为真。
    mutating func digits(radix: Int) throws -> Bool {
        let start = cursor
        while byte(cursor) == 95 || Self.digit(byte(cursor), radix: radix) {
            try budget.consume()
            cursor += 1
        }
        return cursor != start
    }

    /// 业务作用：进制数字仅使用固定 ASCII 范围，区域与 Unicode 数字外观不改变分类。
    /// 参数说明:
    /// - byte: 当前候选原字节。
    /// - radix: 当前进制。
    /// 返回：当前字节属于该进制数字时为真。
    static func digit(_ byte: UInt8, radix: Int) -> Bool {
        if byte >= 48, byte <= 57 {
            return Int(byte - 48) < radix
        }
        return radix == 16 && (byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102)
    }
}
