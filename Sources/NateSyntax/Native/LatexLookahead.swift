import Foundation

extension LatexLexing {
    /// 业务作用：行外证据来自固定正文；无快照时仅保留已提交尾部，不把 NUL 当成源长度。
    /// 参数说明:
    /// - offset: 相对当前范围的原字节位置。
    /// 返回：原始字节或来源之外的空格哨兵。
    func byte(_ offset: Int) -> UInt8 {
        if offset >= 0, offset < bytes.count {
            return bytes[offset]
        }
        if let snapshot, base + offset >= 0, base + offset < snapshot.text.byteCount {
            return snapshot.text.byte(at: base + offset) ?? 0
        }
        if offset < 0, offset >= -state.tail.count {
            return state.tail[state.tail.count + offset]
        }
        return 32
    }

    /// 业务作用：命令名称只接受 ASCII 字母，正文的 Unicode 字节不参与控制词匹配。
    /// 参数说明:
    /// - value: 候选原字节。
    /// 返回：ASCII 大小写字母时为真。
    static func letter(_ value: UInt8) -> Bool {
        value >= 65 && value <= 90 || value >= 97 && value <= 122
    }

    /// 业务作用：固定特殊字符集合区分单字符转义与可选参数内部的独立语法。
    /// 参数说明:
    /// - value: 候选原字节。
    /// 返回：LaTeX 特殊 ASCII 字符时为真。
    static func special(_ value: UInt8) -> Bool {
        [35, 36, 37, 38, 95, 123, 125, 32].contains(value)
    }

    /// 业务作用：可选参数须有完整闭括号证据，跨行前瞻共享当前分析预算。
    /// 参数说明:
    /// - start: 控制词末字节之后的位置。
    /// 返回：空白或星号后存在不含特殊语法的完整方括号参数时为真。
    mutating func optionalArgument(_ start: Int) throws -> Bool {
        var offset = start
        var before = true
        let end =
            snapshot.map {
                $0.text.byteCount - base
            } ?? bytes.count
        while offset < end {
            try budget.consume()
            let current = byte(offset)
            if before {
                if current == 91 {
                    before = false
                }
                else if ![32, 9, 13, 10, 42].contains(current) {
                    return false
                }
            }
            else {
                if current == 93 {
                    return true
                }
                if current > 32 && Self.special(current) {
                    return false
                }
            }
            offset += 1
        }
        return false
    }

    /// 业务作用：环境名称必须在当前物理范围内闭合，错误字节由调用方保留为错误身份。
    /// 参数说明:
    /// - offset: 首个候选位置，结束时停在闭括号或首个非法字节。
    /// 返回：只含字母或星号的花括号标签完整存在时为真，空标签亦可成立。
    mutating func validTag(_ offset: inout Int) throws -> Bool {
        while offset < bytes.count {
            try budget.consume()
            let current = byte(offset)
            if current == 123 {
                while offset < bytes.count {
                    try budget.consume()
                    offset += 1
                    if byte(offset) == 125 {
                        return true
                    }
                    if !Self.letter(byte(offset)) && byte(offset) != 42 {
                        return false
                    }
                }
            }
            else if current != 32 && current != 9 {
                return false
            }
            offset += 1
        }
        return false
    }

    /// 业务作用：完整控制词与环境后缀采用原字节匹配，不做大小写折叠或名称正规化。
    /// 参数说明:
    /// - end: 待匹配后缀的最后字节。
    /// - word: 最多三十一个 ASCII 字节的固定名称。
    /// 返回：后缀逐字节相等时为真。
    func suffix(_ end: Int, _ word: String) -> Bool {
        let expected = Array(word.utf8)
        return expected.count <= 31
            && expected.enumerated().allSatisfy {
                byte(end - expected.count + 1 + $0.offset) == $0.element
            }
    }

    /// 业务作用：数学环境仅接受规定名称及其星号形式，避免任意标签改变外部数学模式。
    /// 参数说明:
    /// - end: 已确认的环境右花括号位置。
    /// 返回：二十字节内完整环境名称属于块数学集合时为真。
    func mathEnvironment(_ end: Int) -> Bool {
        guard byte(end) == 125 else {
            return false
        }
        var start = end - 1
        while base + start >= 0 && byte(start) != 123 {
            if end - start >= 20 {
                return false
            }
            start -= 1
        }
        guard base + start >= 0, start < end - 1 else {
            return false
        }
        var last = end
        if byte(last - 1) == 42 {
            last -= 1
        }
        let name = String(
            decoding: (start + 1..<last).map {
                byte($0)
            },
            as: UTF8.self
        )
        return ["align", "alignat", "flalign", "gather", "multiline", "displaymath", "eqnarray", "equation"]
            .contains(name)
    }
}
