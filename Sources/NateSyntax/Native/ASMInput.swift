import Foundation
import NateCore

extension ASMScanner {
    /// 业务作用：局部状态只引用同一固定正文，真实文档边缘使用 StyleContext 的 NUL 哨兵。
    /// 参数说明:
    /// - position: 当前物理范围中的相对原字节位置。
    /// 返回：实际同源字节或真实边缘哨兵，越界算术或预算不足时拒绝。
    mutating func byte(at position: Int) throws -> UInt8 {
        try budget.consume()
        if position >= 0, position < bytes.count {
            return bytes[position]
        }
        guard let snapshot else {
            return 0
        }
        guard position >= -2, position <= bytes.count + 1,
            position >= 0 ? base <= Int.max - position : base >= -position
        else {
            return 0
        }
        return snapshot.text.byte(at: base + position) ?? 0
    }

    /// 业务作用：续行后的新物理行仍取得独立行首资格，CRLF 中间不重新开始状态。
    /// 参数说明: 无。
    /// 返回：真实文档或物理行首时为真。
    mutating func atLineStart() throws -> Bool {
        if base == 0, cursor == 0 {
            return true
        }
        let previous = try byte(at: cursor - 1)
        return try previous == 10 || previous == 13 && byte(at: cursor) != 10
    }

    /// 业务作用：字符串错误在真实物理结束或 EOF 收束，显示片段不取得虚拟文档结束资格。
    /// 参数说明: 无。
    /// 返回：LF、独立 CR 或真实 EOF 虚拟字符时为真。
    mutating func atLineEnd() throws -> Bool {
        if documentEnd, cursor >= bytes.count {
            return true
        }
        let current = try byte(at: cursor)
        return try current == 10 || current == 13 && byte(at: cursor + 1) != 10
    }

    /// 业务作用：指令注释的闭合范围止于行结束符之前，CRLF 两个字节共同留给普通状态。
    /// 参数说明: 无。
    /// 返回：当前位于真实结束符开端或 EOF 时为真。
    mutating func matchLineEnd() throws -> Bool {
        let current = try byte(at: cursor)
        return current == 13 || current == 10 || documentEnd && cursor >= bytes.count
    }

    /// 业务作用：状态切换只交付此前未确认原字节，名称采用同源前瞻已确认的完整类别。
    /// 参数说明:
    /// - mode: 原生分支授予的新状态。
    /// 返回：此前字节取得完整样式，未知类别或预算不足时拒绝。
    mutating func setState(_ mode: UInt8) throws {
        guard mode <= 16 else {
            throw NateError.invalidRange
        }
        try colour(
            until: min(bytes.count - 1, cursor - 1),
            style: state.mode == 5 ? state.wordStyle : state.mode
        )
        state.mode = mode
    }

    /// 业务作用：字节样式只沿原文顺序发布，虚拟 EOF 不产生额外数据。
    /// 参数说明:
    /// - end: 实际正文中包含在内的末端。
    /// - style: 完整原生样式编号。
    /// 返回：未交付范围取得样式；非法边界或预算不足时拒绝。
    mutating func colour(until end: Int, style: UInt8) throws {
        guard end >= -1, end < bytes.count, style <= 16 else {
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
