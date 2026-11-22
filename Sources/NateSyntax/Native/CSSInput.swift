import Foundation
import NateCore

extension CSSScanner {
    /// 业务作用：当前 CSS 判断使用完整标量，真实 EOF 才使用虚拟 NUL。
    /// 参数说明: 无。
    /// 返回：当前原文标量或真实 EOF 的 NUL 哨兵。
    var current: UInt32 {
        scalar(at: cursor)
    }

    /// 业务作用：有效 UTF-8 按完整标量推进，不拆开选择器和字面字符的编码。
    /// 参数说明:
    /// - offset: 当前缓冲区中的标量开端。
    /// 返回：完整标量宽度，虚拟 EOF 使用一字节推进。
    func width(at offset: Int) -> Int {
        guard offset < bytes.count else {
            return 1
        }
        let first = bytes[offset]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：字符分类取得实际 Unicode 标量，候选截取仍独立保留原 UTF-8 字节。
    /// 参数说明:
    /// - offset: 当前缓冲区中的明确标量边界。
    /// 返回：完整标量或缓冲区末端的 NUL 哨兵。
    func scalar(at offset: Int) -> UInt32 {
        guard offset < bytes.count else {
            return 0
        }
        let count = width(at: offset)
        if count == 1 {
            return UInt32(bytes[offset])
        }
        var value = UInt32(bytes[offset] & (count == 2 ? 31 : (count == 3 ? 15 : 7)))
        for index in 1..<count {
            value = (value << 6) | UInt32(bytes[offset + index] & 63)
        }
        return value
    }

    /// 业务作用：仅同一固定正文授予缓冲区之外的有限后继读取资格，实际光标前缀不得读取后继作为已输入字符。
    /// 参数说明: 无。
    /// 返回：下一完整标量；光标截断或真实 EOF 使用 NUL 哨兵，预算不足时拒绝。
    mutating func next() throws -> UInt32 {
        let offset = cursor + width(at: cursor)
        if offset < bytes.count {
            return scalar(at: offset)
        }
        if prefixOnly {
            return 0
        }
        guard let snapshot, base <= Int.max - offset,
            let first = snapshot.text.byte(at: base + offset)
        else {
            return 0
        }
        try budget.consume()
        if first < 128 {
            return UInt32(first)
        }
        let count = first < 224 ? 2 : (first < 240 ? 3 : 4)
        var value = UInt32(first & (count == 2 ? 31 : (count == 3 ? 15 : 7)))
        for index in 1..<count {
            try budget.consume()
            guard let byte = snapshot.text.byte(at: base + offset + index) else {
                throw NateError.invalidRange
            }
            value = (value << 6) | UInt32(byte & 63)
        }
        return value
    }

    /// 业务作用：缓冲区末端只有真实 EOF 才能参与词元终止，有限前瞻耗尽不能伪装文件结束。
    /// 参数说明: 无。
    /// 返回：当前位置可解释时继续，否则拒绝整批类别。
    mutating func requireCurrent() throws {
        if cursor == bytes.count, !trueEOF, !prefixOnly {
            try extend()
        }
        guard cursor < bytes.count || cursor == bytes.count && trueEOF && !prefixOnly else {
            throw NateError.message("CSS 未决词法段超过有界后继范围。")
        }
    }

    /// 业务作用：CSS 仅为尚未稳定的段按需读取小批后继，短行不重复复制整份前瞻窗口。
    /// 参数说明: 无。
    /// 返回：同源有界完整标量加入缓冲区；达到前瞻上限或缺少来源时拒绝整批类别。
    mutating func extend() throws {
        try budget.check()
        let end = base + bytes.count
        guard let snapshot, end < limitUpper else {
            throw NateError.message("CSS 未决词法段超过有界后继范围。")
        }
        var upper = end + min(256, limitUpper - end)
        while !snapshot.text.isBoundary(upper) {
            try budget.consume()
            upper -= 1
        }
        if snapshot.text.byte(at: upper - 1) == 13, snapshot.text.byte(at: upper) == 10 {
            upper -= 1
        }
        guard upper > end else {
            throw NateError.message("CSS 后继范围缺少完整 UTF-8 或 CRLF 边界。")
        }
        bytes.append(contentsOf: snapshot.text.bytes(in: ByteRange(end, upper)))
        trueEOF = upper == snapshot.text.byteCount
    }
}
