import Foundation
import NateCore

extension SQLScanner {
    /// 业务作用：Q 引号的补码从固定原文读取，跨物理行闭合只能依靠同源实际单引号。
    /// 参数说明: 无。
    /// 返回：当前标量消费；完整闭合后回到代码，跨行闭合则保留待消费单引号。
    mutating func qLiteral() throws {
        let width = scalarWidth(at: cursor)
        // 原生匹配将补码限制为八位，再与完整标量比较，不能让更宽的同形 Unicode 提前闭合。
        if scalar(at: cursor) == state.qComplement & 255,
            try sourceByte(at: cursor + width) == 39
        {
            if cursor + width < bytes.count {
                try consume(width + 1, style: 24)
                state.mode = 0
            }
            else {
                // 先保留补码的字面身份，后继行只有消费已证明的单引号后才能开放代码。
                guard snapshot != nil else {
                    throw NateError.message("SQL Q 引号缺少跨行闭合来源。")
                }
                try consume(width, style: 24)
                state.closingQuotePending = true
            }
        }
        else {
            try consume(width, style: 24)
        }
    }

    /// 业务作用：PLDoc 命令按原生小写字符集和实际终止条件保留已知、未知与紧接闭合的类别。
    /// 参数说明: 无。
    /// 返回：完整命令范围消费，紧接注释闭合时连同闭合符取得错误类别并回到代码。
    mutating func documentation() throws {
        let start = cursor
        var end = cursor + 1
        while end < bytes.count, Self.documentationPart(bytes[end]) {
            try budget.consume()
            end += 1
        }
        if end + 1 < bytes.count, bytes[end] == 42, bytes[end + 1] == 47 {
            try consume(end + 2 - start, style: 18)
            state.mode = 0
            return
        }
        let terminator = try sourceScalar(at: end)
        let candidate = Data(bytes[start..<end].prefix(99).dropFirst())
        let known: Bool
        if Self.isSpace(terminator) {
            known = try rules.contains(candidate, group: 2, budget: &budget)
        }
        else {
            known = false
        }
        try consume(end - start, style: known ? 17 : 18)
    }

    /// 业务作用：PLDoc 名称只接受原生小写和文档符号，后继大写或 Unicode 文本不并入命令。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：该字节属于文档命令后继时为真。
    static func documentationPart(_ byte: UInt8) -> Bool {
        byte >= 97 && byte <= 122 || "$@\\&<>#{}[]".utf8.contains(byte)
    }

    /// 业务作用：有限后继读取保持完整物理分类与固定正文一致，不从另一修订猜测引号边界。
    /// 参数说明:
    /// - offset: 相对当前物理范围的原字节位置。
    /// 返回：同源实际字节；真实 EOF 使用原生 NUL 哨兵，非法位置抛错。
    mutating func sourceByte(at offset: Int) throws -> UInt8 {
        try budget.consume()
        guard offset >= 0, base <= Int.max - offset else {
            throw NateError.invalidRange
        }
        if offset < bytes.count {
            return bytes[offset]
        }
        return snapshot?.text.byte(at: base + offset) ?? 0
    }

    /// 业务作用：Q 补码和文档终止条件按完整 Unicode 标量读取，不把首个 UTF-8 字节误作字符。
    /// 参数说明:
    /// - offset: 相对当前物理范围的明确标量开端。
    /// 返回：完整标量或真实 EOF 的 NUL 哨兵；预算不足时抛错。
    mutating func sourceScalar(at offset: Int) throws -> UInt32 {
        let first = try sourceByte(at: offset)
        if first < 128 {
            return UInt32(first)
        }
        let width = first < 224 ? 2 : (first < 240 ? 3 : 4)
        var value = UInt32(first & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
        for index in 1..<width {
            value = (value << 6) | UInt32(try sourceByte(at: offset + index) & 63)
        }
        return value
    }
}
