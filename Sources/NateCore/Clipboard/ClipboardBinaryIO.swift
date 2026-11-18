import Foundation

struct ClipboardBinaryWriter {
    var data = Data()
    let budget: ClipboardBudget

    /// 业务作用：固定宽度协议字段采用小端编码，不依赖处理器对齐或宿主字节顺序。
    /// 参数说明:
    /// - value: 已受所属字段范围约束的无符号值。
    /// 返回：完整追加该协议字段，不修改来源载荷。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// 业务作用：原始 UTF-8 按有界块复制，取消或超限不能产生可发布的半份载荷。
    /// 参数说明:
    /// - bytes: 当前字段的完整原始字节。
    /// 返回：所有字节追加成功；超过 96 MiB、取消或截止时整体失败。
    mutating func append(_ bytes: Data) throws {
        try budget.check()
        guard bytes.count <= ClipboardLimits.encodedBytes - data.count else {
            throw NateError.message("剪贴板编码超过 96 MiB。")
        }
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            try budget.check()
            let end = cursor + min(8192, bytes.endIndex - cursor)
            data.append(contentsOf: bytes[cursor..<end])
            cursor = end
        }
    }
}

struct ClipboardBinaryReader {
    let data: Data
    let budget: ClipboardBudget
    var cursor = 0

    /// 业务作用：协议字段逐字节读取，截断数据不能触发越界访问或未对齐内存加载。
    /// 参数说明:
    /// - type: 当前字段的固定无符号整数宽度。
    /// 返回：完整字段的小端值；输入不足时明确拒绝。
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let count = T.bitWidth / 8
        guard count <= data.count - cursor else {
            throw NateError.message("剪贴板载荷在协议字段中截断。")
        }
        var value: T = 0
        for offset in 0..<count {
            value |= T(data[data.startIndex + cursor + offset]) << (offset * 8)
        }
        cursor += count
        return value
    }

    /// 业务作用：可变内容先检查剩余长度和单字段容量，再按块读取，不能按声明长度盲目分配。
    /// 参数说明:
    /// - count: 当前原文或格式标记的明确字节数。
    /// 返回：该字段的完整原始数据；超量、截断、取消或超时不返回部分内容。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= ClipboardLimits.contentBytes, count <= data.count - cursor else {
            throw NateError.message("剪贴板原文长度无效、超量或已经截断。")
        }
        var result = Data()
        result.reserveCapacity(count)
        let end = cursor + count
        while cursor < end {
            try budget.check()
            let size = min(8192, end - cursor)
            let start = data.startIndex + cursor
            result.append(contentsOf: data[start..<(start + size)])
            cursor += size
        }
        return result
    }
}
