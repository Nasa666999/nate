import Foundation
import NateCore

extension TOMLScanner {
    /// 业务作用：当前 TOML 判断采用完整标量，只有实际文件末尾使用虚拟 NUL。
    /// 参数说明: 无。
    /// 返回：当前原文标量或真实 EOF 的 NUL 哨兵。
    var current: UInt32 {
        scalar(at: cursor)
    }

    /// 业务作用：UTF-8 标量推进不拆开原文字符，虚拟 EOF 仍可终止原生候选。
    /// 参数说明:
    /// - position: 当前物理缓冲区中的标量开端。
    /// 返回：完整标量宽度，缓冲区末尾使用一字节哨兵宽度。
    func width(at position: Int) -> Int {
        guard position < bytes.count else {
            return 1
        }
        let first = bytes[position]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：原生字符判断取得实际 Unicode 标量，词候选仍独立采用原 UTF-8 字节。
    /// 参数说明:
    /// - position: 当前物理缓冲区中的完整标量开端。
    /// 返回：完整标量或缓冲区末尾的 NUL 哨兵。
    func scalar(at position: Int) -> UInt32 {
        guard position < bytes.count else {
            return 0
        }
        let count = width(at: position)
        if count == 1 {
            return UInt32(bytes[position])
        }
        var value = UInt32(bytes[position] & (count == 2 ? 31 : (count == 3 ? 15 : 7)))
        for index in 1..<count {
            value = (value << 6) | UInt32(bytes[position + index] & 63)
        }
        return value
    }

    /// 业务作用：TOML 后继读取只来自同一固定正文，并与当前物理分类共享前瞻上限。
    /// 参数说明:
    /// - relative: 相对当前标量原字节开端的位置。
    /// 返回：对应原字节或真实 EOF 的 NUL；缺少完整有界来源时拒绝。
    mutating func relativeByte(_ relative: Int) throws -> UInt8 {
        try budget.consume()
        guard relative >= 0, cursor <= Int.max - relative else {
            throw NateError.invalidRange
        }
        let position = cursor + relative
        if position < bytes.count {
            return bytes[position]
        }
        if trueEOF {
            return 0
        }
        guard let snapshot, position - bytes.count <= 1_048_576,
            base <= Int.max - position
        else {
            throw NateError.message("TOML 后继判断超过完整来源或 1 MiB 范围。")
        }
        return snapshot.text.byte(at: base + position) ?? 0
    }

    /// 业务作用：后继标量保持实际编码，有限显示末尾不能冒充源文件 EOF。
    /// 参数说明: 无。
    /// 返回：同源下一完整标量或真实 EOF 的 NUL 哨兵。
    mutating func next() throws -> UInt32 {
        let position = cursor + width(at: cursor)
        if position < bytes.count {
            return scalar(at: position)
        }
        let distance = width(at: cursor), first = try relativeByte(distance)
        if first < 128 {
            return UInt32(first)
        }
        let count = first < 224 ? 2 : (first < 240 ? 3 : 4)
        var value = UInt32(first & (count == 2 ? 31 : (count == 3 ? 15 : 7)))
        for index in 1..<count {
            value = (value << 6) | UInt32(try relativeByte(distance + index) & 63)
        }
        return value
    }
}
