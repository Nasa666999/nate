import Foundation

extension PowerShellLexing {
    var lineStart: Bool {
        cursor == 0 || byte(cursor - 1) == 10 || byte(cursor - 1) == 13 && byte(cursor) != 10
    }

    /// 业务作用：读取越界位置时使用词法哨兵，正文中的 NUL 仍保留为实际原字节。
    /// 参数说明:
    /// - index: 相对当前物理范围的原字节位置。
    /// 返回：范围内原字节，范围外为零，不读取其它正文。
    func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    /// 业务作用：转义和扫描跨越完整 UTF-8 标量，避免续字节取得独立语法身份。
    /// 参数说明:
    /// - index: 已确认的标量起点或当前范围末尾。
    /// 返回：完整标量字节数，范围末尾为零。
    func width(_ index: Int) -> Int {
        guard index < bytes.count else {
            return 0
        }
        let first = bytes[index]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：完成当前片段后才更换类别，数字转名称或未知文档词可以重分类整段前缀。
    /// 参数说明:
    /// - mode: 后继类别，与当前相同时仅完成未发布片段。
    /// 返回：当前完整片段写入局部类别缓冲，预算不足时抛错。
    mutating func change(_ mode: Int) throws {
        for index in segment..<cursor {
            try budget.consume()
            classes[index] = UInt8(state.mode)
        }
        segment = cursor
        state.mode = mode
    }

    /// 业务作用：命令候选沿原生 99 字节窗口与 ASCII 小写规则匹配，六组词表保留优先顺序。
    /// 参数说明:
    /// - documentation: 文档候选跳过点号，独立使用第六词表。
    /// 返回：待发布片段取得对应样式，未知文档词回到块注释，其它未知名称保持名称样式。
    mutating func classify(documentation: Bool) {
        let end = min(cursor, segment + 99)
        let start = min(end, segment + (documentation ? 1 : 0))
        let value = Data(
            bytes[start..<end].prefix(while: {
                $0 != 0
            }).map {
                Self.lower($0)
            }
        )
        if documentation {
            state.mode = rules.groups[5].contains(value) ? 16 : 13
        }
        else {
            state.mode = 7
            for group in 0..<5 where rules.groups[group].contains(value) {
                state.mode = 8 + group
                break
            }
        }
    }

    /// 业务作用：PowerShell 词边界保留非 ASCII 名称、连字符及下划线，不使用 Swift 规范等价比较。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：字母、数字、连字符、下划线或非 ASCII 为真。
    static func word(_ byte: UInt8) -> Bool {
        byte >= 128 || (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 45 || byte == 95
    }

    /// 业务作用：只按语言原生 ASCII 运算符集合进入操作符状态，普通引号和变量另行处理。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：属于明确操作符集合时为真。
    static func isOperator(_ byte: UInt8) -> Bool {
        switch byte {
        case 37, 94, 38, 42, 40, 41, 45, 43, 61, 124, 123, 125, 91, 93, 58, 59, 60, 62,
            44, 47, 63, 33, 46, 126:
            return true
        default: return false
        }
    }

    /// 业务作用：词法大小写转换仅影响 ASCII，原始 Unicode 字节保持独立身份。
    /// 参数说明:
    /// - byte: 候选的当前原字节。
    /// 返回：ASCII 大写转小写，其它字节原样返回。
    static func lower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// 业务作用：数字采用原生外观规则，遇到其它名称字符时整段转为名称，不声称数值有效。
    /// 参数说明:
    /// - previous: 当前字符之前的原字节。
    /// - current: 当前原字节。
    /// - next: 当前字符之后的原字节。
    /// 返回：数字、十六进制字母、小数点、指数符号或原生后缀为真。
    static func numeric(previous: UInt8, current: UInt8, next: UInt8) -> Bool {
        let previous = lower(previous), current = lower(current), next = lower(next)
        return (48...57).contains(current) || current == 120 && previous == 48
            || (97...102).contains(current) || current == 46 && next != 46
            || (current == 43 || current == 45) && previous == 101
            || [103, 107, 108, 109, 110, 112, 115, 116, 117, 121].contains(current)
    }
}
