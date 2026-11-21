import Foundation
import NateCore

private struct TeXField {
    let range: ByteRange
    let style: Int
}

private struct TeXLine {
    let bytes: [UInt8]
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var style = 5
    var comment = false
    var fields: [TeXField] = []

    /// 业务作用：默认空词表中的 TeX 控制词保留命令身份，注释、分组与符号按原字节区分。
    /// 参数说明: 无。
    /// 返回：当前物理行完整字段，失败不发布任何部分呈现。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            if comment {
                if atLineEnd {
                    try setStyle(5)
                    comment = false
                }
            }
            else if !Self.letter(current) {
                if style == 4, cursor - segment == 1 {
                    if current == 94, byte(cursor + 1) == 94 {
                        forward()
                        forward()
                    }
                    forward()
                    try setStyle(5)
                }
                if cursor < bytes.count {
                    try category()
                }
            }
            else if style != 4 {
                try setStyle(5)
            }
            forward()
        }
        try flush(until: bytes.count)
        try budget.check()
    }

    /// 业务作用：TeX 字面类别优先于普通文字，已经转义的控制字符不重新进入注释或分组。
    /// 参数说明: 无。
    /// 返回：当前位置进入固定身份，百分号后的真实行末恢复普通文字。
    mutating func category() throws {
        if current == 37 {
            try setStyle(3)
            let next = byte(cursor + 1)
            if !(next == 10 || next == 13 && byte(cursor + 2) != 10) {
                forward()
                try setStyle(0)
            }
            comment = true
        }
        else if current == 94, byte(cursor + 1) == 94 {
            try setStyle(5)
            forward()
            try setStyle(5)
        }
        else if "[]=#()<>\"".utf8.contains(current) {
            try setStyle(1)
        }
        else if "{}$".utf8.contains(current) {
            try setStyle(2)
        }
        else if "~^_&-+\"`/|%".utf8.contains(current) {
            try setStyle(3)
        }
        else if current == 92 {
            try setStyle(4)
        }
        else {
            try setStyle(5)
        }
    }

    /// 业务作用：控制词采用固定 ASCII 字母及 TeX 附加名称字符，Unicode 原文保持标量边界。
    /// 参数说明:
    /// - byte: 原始候选字节。
    /// 返回：能够延续 TeX 控制词时为真。
    static func letter(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || [64, 33, 63].contains(byte)
    }

    /// 业务作用：当前源字节用于类别判断，末尾候选不借用下一行文字。
    /// 参数说明: 无。
    /// 返回：当前原字节，末尾之外为零。
    var current: UInt8 {
        byte(cursor)
    }

    /// 业务作用：只以真实 CR、LF 或 CRLF 的末字节结束 TeX 注释。
    /// 参数说明: 无。
    /// 返回：当前位置为实际行结束符末端时为真。
    var atLineEnd: Bool {
        current == 10 || current == 13 && byte(cursor + 1) != 10
    }

    /// 业务作用：有限标记只能使用当前完整物理行中已经取得的源证据。
    /// 参数说明:
    /// - offset: 行内原字节位置。
    /// 返回：候选原字节，来源之外为零。
    func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    }

    /// 业务作用：命令控制字符与普通内容按完整 UTF-8 标量推进，转义不切开多字节字符。
    /// 参数说明: 无。
    /// 返回：游标越过一个原始标量，末尾哨兵不生成源范围。
    mutating func forward() {
        let byte = current
        cursor += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
    }

    /// 业务作用：切换身份前封存此前完整源片段，当前字符仅由新身份持有。
    /// 参数说明:
    /// - next: 新的 TeX 固定样式编号。
    /// 返回：此前范围进入有限临时列表。
    mutating func setStyle(_ next: Int) throws {
        try flush(until: min(cursor, bytes.count))
        style = next
    }

    /// 业务作用：TeX 字段保持原始顺序与完整编码边界，并受共同词元容量保护。
    /// 参数说明:
    /// - end: 当前需要封存的原字节末边界。
    /// 返回：非空字段进入临时列表，容量不足时拒绝整行。
    mutating func flush(until end: Int) throws {
        guard end > segment else {
            return
        }
        try budget.consume()
        let start: Int
        if let previous = fields.last, previous.style == style, previous.range.upper == segment {
            start = previous.range.lower
            fields.removeLast()
        }
        else {
            start = segment
        }
        guard fields.count < 65_536 else {
            throw NateError.message("TeX 高亮超过 65536 个词法片段。")
        }
        fields.append(
            TeXField(
                range: ByteRange(start, end),
                style: style
            )
        )
        segment = end
    }
}

extension PropertyLexing {
    /// 业务作用：TeX 基准空词表采用独立物理行规则，不执行宏、不猜测额外命令词典。
    /// 参数说明:
    /// - start: 当前完整物理行起点。
    /// - end: 包含真实结束符的原始末边界。
    /// 返回：完整资源类别进入当前有界呈现，失败不返回部分结果。
    mutating func texLine(_ start: Int, _ end: Int) throws {
        var line = TeXLine(
            bytes: Array(bytes[start..<end]),
            budget: budget
        )
        try line.scan()
        budget = line.budget
        for field in line.fields {
            try budget.consume()
            try emit(start + field.range.lower, start + field.range.upper, style: field.style)
        }
    }
}
