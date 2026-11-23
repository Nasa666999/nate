import Foundation
import NateCore

extension AdaScanner {
    /// 业务作用：Ada 步进读取完整 UTF-8 标量，候选的低八位转换不拆散真实显示范围。
    /// 参数说明:
    /// - position: 当前固定原文中的标量开端或有限 EOF。
    /// 返回：完整标量及字节宽度；非法 UTF-8 或预算不足时抛错。
    mutating func character(at position: Int) throws -> (value: UInt32, width: Int) {
        try budget.consume()
        guard position >= 0 else {
            throw NateError.invalidRange
        }
        guard position < bytes.count else {
            return (0, 1)
        }
        let first = bytes[position]
        if first < 128 {
            return (UInt32(first), 1)
        }
        let width = first < 224 ? 2 : (first < 240 ? 3 : 4)
        guard first >= 194, first <= 244, width <= bytes.count - position else {
            throw NateError.invalidRange
        }
        var value = UInt32(first & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
        for offset in 1..<width {
            try budget.consume()
            let next = bytes[position + offset]
            guard (128...191).contains(next) else {
                throw NateError.invalidRange
            }
            value = value << 6 | UInt32(next & 63)
        }
        guard Unicode.Scalar(value) != nil,
            width == 2 ? value >= 128 : (width == 3 ? value >= 2048 : value >= 65536)
        else {
            throw NateError.invalidRange
        }
        return (value, width)
    }

    /// 业务作用：有限 EOF 的末次原生步进可切换为空格哨兵，不添加实际空白。
    /// 参数说明: 无。
    /// 返回：当前完整标量或已经确认的有限哨兵。
    mutating func current() throws -> UInt32 {
        eofSpace ? 32 : try character(at: cursor).value
    }

    /// 业务作用：双字符开端按完整标量前瞻，不以 UTF-8 后续字节误认撇号或标签。
    /// 参数说明: 无。
    /// 返回：紧邻完整标量或有限边缘哨兵。
    mutating func next() throws -> UInt32 {
        if eofSpace {
            return 32
        }
        let width = try character(at: cursor).width
        return try character(at: cursor + width).value
    }

    /// 业务作用：CRLF 只在 LF 处赋予物理行末资格，末行只在真实 EOF 取得相同边界。
    /// 参数说明: 无。
    /// 返回：当前位置位于原生行末时为真。
    func atLineEnd() -> Bool {
        let end = currentLine + 1 < starts.count ? starts[currentLine + 1] - 1 : bytes.count
        return cursor >= end
    }

    /// 业务作用：原生字符通道的两次先行步进与数值 EOF 收束保留各自顺序，虚拟哨兵不推进实际正文。
    /// 参数说明:
    /// - allowFollowingLine: 当前语法内部步进是否必须消费下一真实物理行。
    /// 返回：完整标量已经消费或有限 EOF 空格哨兵已建立；必要同源后继在容量确认后追加，预算不足时抛错。
    mutating func forward(allowFollowingLine: Bool = true) throws {
        try budget.consume()
        if more() {
            if atLineEnd() {
                currentLine += 1
            }
            previous = try current()
            cursor += try character(at: cursor).width
            if allowFollowingLine && cursor == bytes.count && !documentEnd {
                try appendFollowingLine()
            }
        }
        else if documentEnd {
            previous = 32
            eofSpace = true
        }
    }

    /// 业务作用：只有完整真实上下文及唯一 EOF 哨兵可参与外层分类，普通物理边界不被当作文档结束。
    /// 参数说明: 无。
    /// 返回：仍有真实原文或尚未消费的有限 EOF 时为真。
    func more() -> Bool {
        cursor < bytes.count || documentEnd && cursor == bytes.count
    }

    /// 业务作用：尚未交付的真实原字节先取得旧类别，再切换状态；EOF 不扩展样式数组。
    /// 参数说明:
    /// - mode: 新的原生类别。
    /// 返回：完整待定范围已收束；范围或预算不足时抛错。
    mutating func setState(_ mode: UInt8) throws {
        guard mode <= 11 else {
            throw NateError.invalidRange
        }
        let end = cursor - (cursor > bytes.count ? 2 : 1)
        if end >= emitted {
            guard end < bytes.count else {
                throw NateError.invalidRange
            }
            for index in emitted...end {
                try budget.consume()
                styles[index] = state.mode
            }
            emitted = end + 1
        }
        state.mode = mode
    }

    /// 业务作用：真实闭合符先消费再收束旧通道，完整字面不会被拆成闭合符之外的孤立类别。
    /// 参数说明:
    /// - mode: 消费后进入的新类别。
    /// 返回：完整标量与类别都已推进；预算不足时抛错。
    mutating func forwardState(_ mode: UInt8) throws {
        try forward()
        try setState(mode)
    }
}
