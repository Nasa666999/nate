import Foundation

enum JSONNumbers {
    /// 业务作用：按当前 JSON 方言验证完整数字原文，任意精度字面量不被浮点转换截断或溢出。
    /// 参数说明:
    /// - bytes: 已与相邻结构分开的完整候选原字节。
    /// - extended: 是否采用 JSON5 的符号、十六进制、特殊值和省略小数位规则。
    /// - budget: 本行所有词元共同消耗的执行预算。
    /// 返回：整份候选符合数字词法时为真，残缺或多余字符为假；预算失败抛错。
    static func valid(_ bytes: ArraySlice<UInt8>, extended: Bool, budget: inout JSONLexingBudget) throws
        -> Bool
    {
        guard !bytes.isEmpty else {
            return false
        }
        var index = bytes.startIndex
        if bytes[index] == 43 || bytes[index] == 45 {
            if bytes[index] == 43 && !extended {
                return false
            }
            index += 1
        }
        guard index < bytes.endIndex else {
            return false
        }
        if extended {
            let rest = bytes[index...]
            if rest.elementsEqual("Infinity".utf8) || rest.elementsEqual("NaN".utf8) {
                return true
            }
            if bytes[index] == 48, index + 1 < bytes.endIndex,
                bytes[index + 1] == 120 || bytes[index + 1] == 88
            {
                index += 2
                let start = index
                while index < bytes.endIndex && hexadecimal(bytes[index]) {
                    try budget.consume()
                    index += 1
                }
                return index > start && index == bytes.endIndex
            }
        }
        var integer = false
        if bytes[index] == 48 {
            integer = true
            index += 1
            if index < bytes.endIndex && decimal(bytes[index]) {
                return false
            }
        }
        else if (49...57).contains(bytes[index]) {
            integer = true
            try digits(bytes, index: &index, budget: &budget)
        }
        if index < bytes.endIndex && bytes[index] == 46 {
            index += 1
            let start = index
            try digits(bytes, index: &index, budget: &budget)
            guard extended ? integer || index > start : integer && index > start else {
                return false
            }
        }
        else if !integer {
            return false
        }
        if index < bytes.endIndex && (bytes[index] == 69 || bytes[index] == 101) {
            index += 1
            if index < bytes.endIndex && (bytes[index] == 43 || bytes[index] == 45) {
                index += 1
            }
            let start = index
            try digits(bytes, index: &index, budget: &budget)
            guard index > start else {
                return false
            }
        }
        return index == bytes.endIndex
    }

    /// 业务作用：十进制数字只采用 ASCII 原字节，非 ASCII 数字不冒充 JSON 数字语法。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：属于零至九时为真。
    static func decimal(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：十六进制转义和数字共用同一完整 ASCII 字母范围。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：零至九、A 至 F 或 a 至 f 时为真。
    static func hexadecimal(_ byte: UInt8) -> Bool {
        decimal(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    /// 业务作用：整数、小数与指数逐位使用同一工作量，不为长数字另取处理时间。
    /// 参数说明:
    /// - bytes: 当前完整候选。
    /// - index: 当前读取位置，完成后位于首个非数字处。
    /// - budget: 本行共同预算。
    /// 返回：只推进合法数字，取消或超限时抛错。
    private static func digits(_ bytes: ArraySlice<UInt8>, index: inout Int, budget: inout JSONLexingBudget)
        throws
    {
        while index < bytes.endIndex && decimal(bytes[index]) {
            try budget.consume()
            index += 1
        }
    }
}
