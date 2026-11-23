import Foundation
import NateCore

extension ASN1Scanner {
    /// 业务作用：原生扫描按完整 Unicode 标量推进，ASCII 名称判断不拆开真实显示字符。
    /// 参数说明:
    /// - position: 固定上下文中的标量起点或有限 EOF。
    /// 返回：完整标量与字节宽度；非法 UTF-8 或共同预算不足时抛错。
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

    /// 业务作用：当前类别只依据完整原文标量，真实 NUL 与有限 EOF 仍按原生通道分别收束。
    /// 参数说明: 无。
    /// 返回：当前位置的完整标量或有限 NUL 哨兵。
    mutating func current() throws -> UInt32 {
        try character(at: cursor).value
    }

    /// 业务作用：注释开端只比较相邻完整标量，不以多字节字符的后续字节冒充连字符。
    /// 参数说明: 无。
    /// 返回：紧邻完整标量或有限边缘哨兵。
    mutating func next() throws -> UInt32 {
        let width = try character(at: cursor).width
        return try character(at: cursor + width).value
    }

    /// 业务作用：真实全文允许唯一 EOF 分类动作，普通物理边界只传播已有连续通道。
    /// 参数说明: 无。
    /// 返回：尚有原文或尚未消费的真实 EOF 时为真。
    func more() -> Bool {
        cursor < bytes.count || documentEnd && cursor == bytes.count
    }

    /// 业务作用：实际标量完整消费后保存其原生前驱资格，OID 数字不借另一位置的字节取得类别。
    /// 参数说明: 无。
    /// 返回：当前位置按完整标量推进；已越过有限上下文时不生成额外输入，预算不足时抛错。
    mutating func forward() throws {
        try budget.consume()
        guard more() else {
            return
        }
        previous = try current()
        cursor += try character(at: cursor).width
    }

    /// 业务作用：旧类别的全部待定原字节先收束，再切换状态，虚拟 EOF 不扩展实际样式范围。
    /// 参数说明:
    /// - mode: 当前明确的新原生类别。
    /// 返回：有限真实字节范围已赋予旧类别；范围、类别或预算不足时整份抛错。
    mutating func setState(_ mode: UInt8) throws {
        guard mode <= 10 else {
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
}
