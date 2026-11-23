import Foundation
import NateCore

extension FortranScanner {
    /// 业务作用：相对原字节读取采用原生 NUL 哨兵，不把文档边缘当作无限空白。
    /// 参数说明:
    /// - position: 当前固定字节范围中的位置。
    /// 返回：实际原字节或真实边缘哨兵；预算不足时拒绝。
    mutating func byte(at position: Int) throws -> UInt8 {
        try budget.consume()
        if bytes.indices.contains(position) {
            return bytes[position]
        }
        guard let snapshot, position >= 0, position <= bytes.count + 132,
            base >= 0, base <= Int.max - position
        else {
            return 0
        }
        return snapshot.text.byte(at: base + position) ?? 0
    }

    /// 业务作用：词法步进按完整 Unicode 标量进行，固定列与名称比较仍保留真实原字节位置。
    /// 参数说明:
    /// - position: 当前原文中的标量开端或边缘。
    /// 返回：完整标量及其原字节宽度；不是完整 UTF-8 时拒绝。
    mutating func character(at position: Int) throws -> (value: UInt32, width: Int) {
        let first = try byte(at: position)
        if first < 128 {
            return (UInt32(first), 1)
        }
        let width = first < 224 ? 2 : (first < 240 ? 3 : 4)
        let available: Int
        if bytes.indices.contains(position) {
            available = bytes.count - position
        }
        else if let snapshot, position >= 0, base >= 0, base <= snapshot.text.byteCount,
            position <= snapshot.text.byteCount - base
        {
            available = snapshot.text.byteCount - base - position
        }
        else {
            throw NateError.invalidRange
        }
        guard first >= 194, first <= 244, position >= 0, width <= available else {
            throw NateError.invalidRange
        }
        var value = UInt32(first & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
        for offset in 1..<width {
            let next = try byte(at: position + offset)
            guard (128...191).contains(next) else {
                throw NateError.invalidRange
            }
            value = (value << 6) | UInt32(next & 63)
        }
        guard Unicode.Scalar(value) != nil,
            width == 2 ? value >= 128 : (width == 3 ? value >= 2048 : value >= 65536)
        else {
            throw NateError.invalidRange
        }
        return (value, width)
    }

    /// 业务作用：当前类别判断只读取完整标量，不把多字节字符拆成多个输入动作。
    /// 参数说明: 无。
    /// 返回：当前真实标量或原生边缘哨兵。
    mutating func current() throws -> UInt32 {
        try character(at: cursor).value
    }

    /// 业务作用：相邻引号与数字开端只查看下一个完整标量，原始距离前瞻另走字节接口。
    /// 参数说明: 无。
    /// 返回：紧邻完整标量或原生边缘哨兵。
    mutating func next() throws -> UInt32 {
        let width = try character(at: cursor).width
        return try character(at: cursor + width).value
    }

    /// 业务作用：真实 EOF 参与一次原生状态收束，不生成额外正文数据。
    /// 参数说明: 无。
    /// 返回：尚有实际标量或唯一 EOF 哨兵可解释时为真。
    func more() -> Bool {
        cursor < bytes.count || documentEnd && cursor == bytes.count
    }

    /// 业务作用：CRLF 在 LF 处取得物理行末资格，最后一行只在真实 EOF 收束。
    /// 参数说明: 无。
    /// 返回：当前真实位置属于原生物理行末时为真。
    func atLineEnd() -> Bool {
        let limit = currentLine + 1 < starts.count ? starts[currentLine + 1] - 1 : bytes.count
        return cursor >= limit
    }

    /// 业务作用：推进完整原文标量并保留显式行首资格，状态分支中的推进不会被外层循环补算。
    /// 参数说明:
    /// - allowFollowingLine: 当前语法动作是否必须读取下一真实物理行。
    /// 返回：当前位置及物理行状态前进；必要后继原文在容量确认后追加，预算或边界不足时拒绝。
    mutating func forward(allowFollowingLine: Bool = true) throws {
        try budget.consume()
        guard more() else {
            atLineStart = false
            return
        }
        atLineStart = atLineEnd()
        if atLineStart {
            currentLine += 1
        }
        cursor += try character(at: cursor).width
        if allowFollowingLine, cursor == bytes.count, !documentEnd {
            try appendFollowingLine()
        }
    }

    /// 业务作用：只给尚未交付的真实原字节赋予完整类别，虚拟 EOF 不扩展样式数组。
    /// 参数说明:
    /// - mode: 新的明确原生类别。
    /// 返回：此前待定字节取得旧类别，当前状态切换；非法类别或预算不足时拒绝。
    mutating func setState(_ mode: UInt8) throws {
        guard mode <= 14 else {
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

    /// 业务作用：闭合引号、错误行尾及固定列续行先消费当前完整标量，再发布相应类别。
    /// 参数说明:
    /// - mode: 推进后的原生类别。
    /// 返回：消费当前标量并收束旧状态；失败不交付外部结果。
    mutating func forwardState(_ mode: UInt8) throws {
        try forward()
        try setState(mode)
    }
}
