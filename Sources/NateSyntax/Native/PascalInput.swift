import Foundation
import NateCore

extension PascalScanner {
    /// 业务作用：前后字节只来自同一正文及固定物理范围，真实文件边缘使用原生 NUL 哨兵。
    /// 参数说明:
    /// - position: 当前完整物理范围中的相对原字节位置。
    /// 返回：实际同源字节或真实边缘哨兵；越界算术与预算不足拒绝整份扫描。
    mutating func byte(at position: Int) throws -> UInt8 {
        try budget.consume()
        if position >= 0, position < bytes.count {
            return bytes[position]
        }
        guard let snapshot else {
            return 0
        }
        if position < 0 {
            guard position >= -4, base >= -position else {
                return 0
            }
        }
        else {
            guard position <= bytes.count + 1, base <= Int.max - position else {
                throw NateError.invalidRange
            }
        }
        return snapshot.text.byte(at: base + position) ?? 0
    }

    /// 业务作用：行首资格只由真实物理结束符授予，CRLF 中间不是新物理行。
    /// 参数说明: 无。
    /// 返回：文档起点、LF 后或非 CRLF 的 CR 后为真。
    mutating func atLineStart() throws -> Bool {
        if base == 0, cursor == 0 {
            return true
        }
        let previous = try byte(at: cursor - 1)
        if previous == 10 {
            return true
        }
        guard previous == 13 else {
            return false
        }
        return try byte(at: cursor) != 10
    }

    /// 业务作用：错误字符串在完整物理结束或真实 EOF 收束，显示片段尾部不冒充文档结束。
    /// 参数说明: 无。
    /// 返回：LF、非 CRLF 的 CR 或真实 EOF 虚拟字符时为真。
    mutating func atLineEnd() throws -> Bool {
        if documentEnd, cursor >= bytes.count {
            return true
        }
        let current = try byte(at: cursor)
        if current == 10 {
            return true
        }
        guard current == 13 else {
            return false
        }
        return try byte(at: cursor + 1) != 10
    }

    /// 业务作用：多引号字面保留完整开端数量，不能把五或七引号按三引号提前结束。
    /// 参数说明: 无。
    /// 返回：当前真实原文中连续单引号数量，所有读取共用扫描预算。
    mutating func quoteCount() throws -> Int {
        var count = 0
        while try byte(at: cursor + count) == 39 {
            count += 1
        }
        return count
    }

    /// 业务作用：状态收束只发布此前完整片段，新状态从当前字符开始，错误字面可在收束前整体重新分类。
    /// 参数说明:
    /// - mode: 当前原生分支授予的新类别。
    /// 返回：此前未交付原字节固定为旧类别，后续片段采用新类别；未知类别拒绝。
    mutating func setState(_ mode: UInt8) throws {
        guard mode <= 15 else {
            throw NateError.invalidRange
        }
        try colour(until: min(bytes.count - 1, cursor - 1), style: state.mode)
        state.mode = mode
    }

    /// 业务作用：分类沿原字节顺序推进，虚拟 EOF 不产生额外字符，也不能覆盖已经收束的片段。
    /// 参数说明:
    /// - end: 当前实际原文字节中包含在内的末端。
    /// - style: 完整片段所属原生类别。
    /// 返回：尚未交付的完整字节取得同一类别，未知范围或超量时拒绝整份结果。
    mutating func colour(until end: Int, style: UInt8) throws {
        guard end >= -1, end < bytes.count, style <= 15 else {
            throw NateError.invalidRange
        }
        if end < emitted {
            return
        }
        for index in emitted...end {
            try budget.consume()
            styles[index] = style
        }
        emitted = end + 1
    }
}
