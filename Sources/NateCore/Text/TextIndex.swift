import Foundation

extension PieceTree {
    /// 业务作用：将系统 UTF-16 坐标转换到内核字节坐标，不接受半代理项。
    /// 参数说明:
    /// - offset: 系统文本服务的 UTF-16 位置。
    /// 返回：合法标量边界的字节位置；越界或半代理项为空。
    public func byteOffset(utf16 offset: Int) -> Int? {
        guard offset >= 0, offset <= utf16Count else {
            return nil
        }
        // 合法 UTF-8 的两种计数相等证明整棵正文都是 ASCII，坐标可直接换算而不反复解码叶片。
        if root.count == root.utf16Count {
            return offset
        }
        var node = root
        var remaining = offset
        var base = 0
        while let left = node.left, let right = node.right {
            if remaining < left.utf16Count {
                node = left
            }
            else {
                remaining -= left.utf16Count
                base += left.count
                node = right
            }
        }
        if node.count == node.utf16Count {
            return base + remaining
        }
        var units = 0
        var bytes = 0
        for scalar in String(decoding: node.bytes, as: UTF8.self).unicodeScalars {
            if units == remaining {
                return base + bytes
            }
            units += scalar.value > 0xFFFF ? 2 : 1
            bytes += scalar.utf8.count
        }
        return units == remaining ? base + bytes : nil
    }

    /// 业务作用：向 AppKit 提供与同一快照一致的 UTF-16 位置。
    /// 参数说明:
    /// - offset: 合法 UTF-8 字节位置。
    /// 返回：对应 UTF-16 单元数；非法边界为空。
    public func utf16Offset(byte offset: Int) -> Int? {
        guard isBoundary(offset) else {
            return nil
        }
        // 整体或落点叶片满足 ASCII 计数证明时保留原偏移，其它正文仍按真实标量累计 UTF-16 单元。
        if root.count == root.utf16Count {
            return offset
        }
        var node = root
        var remaining = offset
        var units = 0
        while let left = node.left, let right = node.right {
            if remaining < left.count {
                node = left
            }
            else {
                remaining -= left.count
                units += left.utf16Count
                node = right
            }
        }
        if node.count == node.utf16Count {
            return units + remaining
        }
        return units + String(decoding: node.bytes.prefix(remaining), as: UTF8.self).utf16.count
    }

    /// 业务作用：严格转换系统范围，拒绝哨兵值和越界输入。
    /// 参数说明:
    /// - range: 同一快照上的 UTF-16 半开范围。
    /// 返回：能够无损映射的 UTF-8 范围。
    public func byteRange(_ range: NSRange) -> ByteRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= utf16Count, range.length <= utf16Count - range.location,
            let a = byteOffset(utf16: range.location),
            let b = byteOffset(utf16: range.location + range.length)
        else {
            return nil
        }
        return ByteRange(a, b)
    }

    /// 业务作用：转换选区供原生文本服务读取。
    /// 参数说明:
    /// - range: 当前快照的字节范围。
    /// 返回：合法 UTF-16 范围，失败不返回伪造位置。
    public func nsRange(_ range: ByteRange) -> NSRange? {
        guard let a = utf16Offset(byte: range.lower), let b = utf16Offset(byte: range.upper), b >= a else {
            return nil
        }
        return NSRange(location: a, length: b - a)
    }

    /// 业务作用：按真实换行查找指定逻辑行，软换行不改变行号。
    /// 参数说明:
    /// - line: 从零开始的逻辑行号。
    /// 返回：行首字节；超出末行时返回文档末端。
    public func lineStart(_ line: Int) -> Int {
        guard line > 0 else {
            return 0
        }
        guard line < lineCount else {
            return byteCount
        }
        let result = Self.breakEnd(root, number: line, previousCR: false)
        if result > 0, byte(at: result - 1) == 13, byte(at: result) == 10 {
            return result + 1
        }
        return result
    }

    /// 业务作用：提供保留换行的完整逻辑行范围。
    /// 参数说明:
    /// - line: 从零开始的行号。
    /// - includeEnding: 是否包含该行实际换行字节。
    /// 返回：文档内有效范围。
    public func lineRange(_ line: Int, includeEnding: Bool = true) -> ByteRange {
        let start = lineStart(line)
        var end = lineStart(line + 1)
        if !includeEnding {
            if end > start, byte(at: end - 1) == 10 {
                end -= 1
            }
            if end > start, byte(at: end - 1) == 13 {
                end -= 1
            }
        }
        return ByteRange(start, max(start, end))
    }

    /// 业务作用：沿字节索引累计前缀换行数，只扫描一个叶片，避免逐次行首查找放大定位成本。
    /// 参数说明:
    /// - offset: 当前快照字节位置。
    /// 返回：从零开始的逻辑行号；越界位置夹到文档边界，CRLF 两字节之间仍属于前一行。
    public func lineNumber(at offset: Int) -> Int {
        let target = min(max(0, offset), byteCount)
        guard target > 0, root.breaks > 0 else {
            return 0
        }
        guard target < byteCount else {
            return root.breaks
        }
        var node = root
        var index = target
        var breaks = 0
        var previous: UInt8 = 0
        while let left = node.left, let right = node.right {
            if index < left.count {
                node = left
            }
            else {
                // 完整子树已缓存换行数，跨树的 CRLF 仍只占一个逻辑换行。
                breaks += left.breaks - (previous == 13 && left.first == 10 ? 1 : 0)
                if let last = left.last {
                    previous = last
                }
                index -= left.count
                node = right
            }
        }
        for byte in node.bytes.prefix(index) {
            if byte == 13 || (byte == 10 && previous != 13) {
                breaks += 1
            }
            previous = byte
        }
        // 前缀末尾的 CR 若紧接未消费的 LF，整对换行尚未结束，不能提前进入下一行。
        if previous == 13 {
            let next = index < node.count ? node.bytes[index] : byte(at: target)
            if next == 10 {
                breaks -= 1
            }
        }
        return breaks
    }

    /// 业务作用：单次逐字移动采用固定 Unicode 扩展字形簇，CRLF 不被切开，也不复制逻辑行。
    /// 参数说明:
    /// - offset: 当前字节位置。
    /// - forward: 是否向后一个字形移动。
    /// 返回：相邻完整边界；文档端点保持不变，非法位置、取消或上下文预算不足失败。
    public func graphemeBoundary(from offset: Int, forward: Bool) throws -> Int {
        var navigation = try GraphemeNavigation(text: self)
        return try navigation.boundary(from: offset, forward: forward)
    }

    /// 业务作用：在缓存换行数帮助下定位行界，跨叶片 CRLF 按一个换行处理。
    /// 参数说明:
    /// - node: 当前子树。
    /// - number: 子树内第几个有效换行。
    /// - previousCR: 前一子树末字节是否为 CR。
    /// 返回：该换行结束的局部偏移。
    private static func breakEnd(_ node: PieceNode, number: Int, previousCR: Bool) -> Int {
        if let left = node.left, let right = node.right {
            let count = left.breaks - (previousCR && left.first == 10 ? 1 : 0)
            if number <= count {
                return breakEnd(left, number: number, previousCR: previousCR)
            }
            return left.count + breakEnd(right, number: number - count, previousCR: left.last == 13)
        }
        var remaining = number
        var previous: UInt8 = previousCR ? 13 : 0
        for (index, byte) in node.bytes.enumerated() {
            if byte == 13 || (byte == 10 && previous != 13) {
                remaining -= 1
                if remaining == 0 {
                    return index + 1
                }
            }
            previous = byte
        }
        return node.count
    }
}
