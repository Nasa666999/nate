import Foundation

struct UDLNumberScanner {
    let rules: UDLNumberRules
    let bytes: [UInt8]
    let start: Int
    let ends: Set<UInt8>
    let budget: UDLScanBudget

    /// 业务作用：数字前缀、附加字符、后缀、范围及科学计数沿同一完整候选确认，非法延续不截取数字前段。
    /// 参数说明: 无。
    /// 返回：出现完整结束证据时给出原字节长度，条件不符时为空；超量或取消抛错，调用方不得发布部分样式。
    func length() throws -> Int? {
        var dot = false, prefix1 = false, prefix2 = false, suffix1 = false, suffix2 = false
        var extras2 = false, range = false, exponent = false, afterRange = false
        var offset = 0
        if rules.isDecimal(byte(0)), UDLNumberRules.digit(byte(1)) {
            dot = true
            offset = 2
        }
        else {
            if let size = try match(byte(0) == 45 ? 8 : 1, at: 0) {
                if let extra = try match(2, at: size) {
                    offset = size + extra
                    prefix2 = true
                    exponent = true
                }
                else if UDLNumberRules.digit(byte(size)) {
                    offset = size + 1
                    prefix2 = true
                    exponent = true
                }
            }
            if !prefix2, let size = try match(byte(0) == 45 ? 7 : 0, at: 0),
                UDLNumberRules.digit(byte(size))
            {
                offset = size + 1
                prefix1 = true
                exponent = true
            }
            if !prefix1 && !prefix2, let size = try match(byte(0) == 45 ? 9 : 3, at: 0) {
                offset = size
                extras2 = true
                exponent = true
            }
        }
        if offset == 0 {
            if UDLNumberRules.digit(byte(0)) {
                offset = 1
            }
            else if [43, 45].contains(byte(0)), UDLNumberRules.digit(byte(1)),
                start == 0 || !UDLNumberRules.digit(bytes[start - 1])
            {
                offset = 2
            }
            else {
                return nil
            }
        }
        while true {
            try budget.consume()
            let current = byte(offset)
            if current > 0 && current < 33 || ends.contains(current) {
                return extras2 && !suffix1 ? nil : offset
            }
            if !range, let size = try match(6, at: offset) {
                guard !extras2 || suffix1 else {
                    return nil
                }
                offset += size
                suffix1 = false
                suffix2 = false
                dot = false
                range = true
                exponent = false
                extras2 = false
                afterRange = true
                continue
            }
            if suffix2 {
                return nil
            }
            if prefix2, let size = try match(2, at: offset) {
                offset += size
                continue
            }
            if !suffix1 && !prefix1 && !prefix2 {
                if let size = try match(4, at: offset) {
                    offset += size
                    extras2 = false
                    suffix1 = true
                    continue
                }
                if let size = try match(3, at: offset) {
                    offset += size
                    extras2 = true
                    exponent = true
                    continue
                }
            }
            if !suffix2, let size = try match(5, at: offset) {
                offset += size
                suffix2 = true
                continue
            }
            if afterRange {
                if let size = try match(1, at: offset) {
                    offset += size
                    exponent = false
                    prefix2 = true
                    continue
                }
                if let size = try match(0, at: offset) {
                    offset += size
                    exponent = false
                    prefix1 = true
                    continue
                }
            }
            if UDLNumberRules.digit(current) {
                offset += 1
                continue
            }
            if !dot, rules.isDecimal(current), UDLNumberRules.digit(byte(offset + 1)),
                UDLNumberRules.digit(byte(offset - 1)) || afterRange
            {
                offset += 2
                dot = true
                continue
            }
            if !exponent, current == 69 || current == 101,
                UDLNumberRules.digit(byte(offset - 1))
            {
                let next = byte(offset + 1)
                let move =
                    UDLNumberRules.digit(next)
                    ? 1 : [43, 45].contains(next) && UDLNumberRules.digit(byte(offset + 2)) ? 2 : 0
                if move > 0 {
                    offset += move
                    prefix2 = false
                    dot = false
                    exponent = true
                    continue
                }
            }
            return nil
        }
    }

    /// 业务作用：数值候选只读取当前完整物理行，不借后续行或越界字节构造终止证据。
    /// 参数说明:
    /// - offset: 相对候选开端的位置。
    /// 返回：范围内的原字节，范围外为不提供有效结束证据的零值。
    private func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count - start ? bytes[start + offset] : 0
    }

    /// 业务作用：规则比较复用当前候选位置及本行预算，不能在每段后缀重新授予运行资格。
    /// 参数说明:
    /// - group: 当前前缀、额外字符、后缀或范围规则组。
    /// - offset: 相对候选开端的实际匹配位置。
    /// 返回：首个完整匹配长度，缺少原文字节时为空；资格或工作量不足时抛错。
    private func match(_ group: Int, at offset: Int) throws -> Int? {
        guard offset >= 0, offset <= bytes.count - start else {
            return nil
        }
        return try rules.first(group, in: bytes, at: start + offset, budget: budget)
    }
}
