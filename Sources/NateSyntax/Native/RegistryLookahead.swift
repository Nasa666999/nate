import Foundation

extension RegistryLexing {
    /// 业务作用：当前原字节或越界哨兵用于独立状态判断，不把源 NUL 当成正文结束。
    /// 参数说明: 无。
    /// 返回：当前行内的原字节，末尾之外为零。
    var current: UInt8 {
        cursor < bytes.count ? bytes[cursor] : 0
    }

    /// 业务作用：只把真实 CR、LF、CRLF 末端作为物理行边界，保留基准的续行位置规则。
    /// 参数说明: 无。
    /// 返回：当前位置是当前真实结束符末端时为真。
    var atLineEnd: Bool {
        current == 10 || current == 13 && byte(at: cursor + 1) != 10
    }

    /// 业务作用：有限前后证据优先来自同一快照，无快照时仅使用已提供字节及三个原始尾字节。
    /// 参数说明:
    /// - offset: 相对当前行起点的位置。
    /// 返回：可确认的原字节，来源之外的候选使用零哨兵。
    func byte(at offset: Int) -> UInt8 {
        if offset >= 0, offset < bytes.count {
            return bytes[offset]
        }
        if let snapshot, base + offset >= 0, base + offset < snapshot.text.byteCount {
            return snapshot.text.byte(at: base + offset) ?? 0
        }
        if offset < 0, offset >= -state.tail.count {
            return state.tail[state.tail.count + offset]
        }
        return 0
    }

    /// 业务作用：ASCII 字母只用于 Registry 类型起点，不对正文做 Unicode 大小写或名称合并。
    /// 参数说明:
    /// - byte: 原始候选字节。
    /// 返回：ASCII 字母时为真。
    static func alpha(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }

    /// 业务作用：十六进制和参数数字采用固定 ASCII 范围，区域设置不改变文件含义。
    /// 参数说明:
    /// - byte: 原始候选字节。
    /// 返回：ASCII 十进制数字时为真。
    static func digit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// 业务作用：只在已经取得值数据身份时识别十六进制数字，键名文字不被推测为数值。
    /// 参数说明:
    /// - byte: 原始候选字节。
    /// 返回：ASCII 十六进制数字时为真。
    static func hex(_ byte: UInt8) -> Bool {
        digit(byte) || byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102
    }

    /// 业务作用：固定十字节前瞻确认类型候选，保留源 NUL 对证据的截断作用。
    /// 参数说明:
    /// - start: 当前类型候选字节。
    /// 返回：后续十字节内先遇到冒号时为真，NUL 或证据不足时为假。
    mutating func valueType(at start: Int) throws -> Bool {
        for offset in 1...10 {
            try budget.consume()
            let byte = byte(at: start + offset)
            if byte == 58 {
                return true
            }
            if byte == 0 {
                return false
            }
        }
        return false
    }

    /// 业务作用：值名等号与删除键标记仅跳过规定范围内的 ASCII 空白，不跨越真实行结束。
    /// 参数说明:
    /// - start: 引号或方括号所在位置。
    /// - expected: 当前业务要求的确切 ASCII 标记。
    /// 返回：百字节内首个非空白字节为指定标记时为真。
    mutating func nextNonWhitespace(at start: Int, is expected: UInt8) throws -> Bool {
        for offset in 1...100 {
            try budget.consume()
            let current = byte(at: start + offset)
            if current == expected {
                return true
            }
            let space = current == 32 || current >= 9 && current <= 13
            if !space || current == 10 || current == 13 && byte(at: start + offset + 1) != 10 {
                return false
            }
        }
        return false
    }

    /// 业务作用：引号后的完整等号证据区分值名称与值字符串，反斜杠保留下一原字节。
    /// 参数说明:
    /// - start: 当前开始引号的位置。
    /// 返回：本物理行内存在合法结束引号与等号时为真，NUL 或行末不足时为假。
    mutating func valueName(at start: Int) throws -> Bool {
        var offset = start + 1
        var escaped = false
        while true {
            try budget.consume()
            let current = byte(at: offset)
            let end = current == 10 || current == 13 && byte(at: offset + 1) != 10
            if escaped {
                escaped = false
            }
            else {
                escaped = current == 92
                if current == 34 {
                    return try nextNonWhitespace(at: offset, is: 61)
                }
                if current == 0 {
                    return false
                }
            }
            if end {
                return false
            }
            offset += 1
        }
    }

    /// 业务作用：只让物理行最后一个闭方括号结束键路径，多个方括号或末尾 NUL 保留原路径身份。
    /// 参数说明:
    /// - start: 当前闭方括号位置。
    /// 返回：后续先遇真实行末时为真，另一个闭括号、NUL 或来源不足时为假。
    mutating func keyPathEnd(at start: Int) throws -> Bool {
        var offset = start + 1
        while true {
            try budget.consume()
            let current = byte(at: offset)
            if current == 93 || current == 0 {
                return false
            }
            if current == 10 || current == 13 && byte(at: offset + 1) != 10 {
                return true
            }
            offset += 1
        }
    }

    /// 业务作用：GUID 呈现采用固定宽度的十六进制或连字符候选，不执行注册表名称解析。
    /// 参数说明:
    /// - start: 已确认的左花括号位置。
    /// 返回：三十六个候选字节及紧随的右花括号完整存在时为真。
    mutating func guid(at start: Int) throws -> Bool {
        for offset in 1...36 {
            try budget.consume()
            let current = byte(at: start + offset)
            guard Self.hex(current) || current == 45 else {
                return false
            }
        }
        return byte(at: start + 37) == 125
    }
}
