import Foundation

public struct ASCIITabColumns: Sendable {
    public static let maximumLineProjections = 1024
    static let maximumBytes = 1_073_741_824
    public let range: ByteRange
    public let tabWidth: Int
    public let columnCount: Int
    private let sourceIdentity: UUID
    private let text: PieceTree
    private let checkpoints: [Int]
    private static let checkpointBytes = 1024

    private enum SourceError: Error {
        case unsupportedByte
    }

    /// 业务作用：后台确认一条长行的原始 ASCII 与 Tab 并建立稀疏原字节列索引，视口无需重扫全部前缀。
    /// 参数说明:
    /// - text: 当前已提交的不可变正文树。
    /// - range: 完整逻辑行正文，结束符不计入布局。
    /// - tabWidth: 当前语言实际启用的 Tab 列数。
    /// - deadline: 本轮完整测量的共同截止。
    /// 返回：合法范围内全部字节经过映射后建立索引；任一其它字符、非法范围或宽度不授予等宽资格。
    public init?(
        text source: PieceTree,
        range: ByteRange,
        tabWidth: Int,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws {
        guard (1...32).contains(tabWidth), source.isBoundary(range.lower), source.isBoundary(range.upper),
            range.lower <= range.upper, range.count <= Self.maximumBytes
        else {
            return nil
        }
        let slice = try source.slicing(range)
        var position = 0
        var column = 0
        var nextCheckpoint = Self.checkpointBytes
        var columns = [0]
        columns.reserveCapacity(1 + slice.byteCount / Self.checkpointBytes)
        do {
            try slice.forEachChunk(maximumBytes: 65_536) { chunk in
                try Self.check(deadline)
                if chunk.tree.isPrintableASCII(in: ByteRange(0, chunk.byteCount)) {
                    // 纯 ASCII 子树已有完整字节证据，直接累计它覆盖的检查点与列距离。
                    let end = position + chunk.byteCount
                    while nextCheckpoint <= end {
                        columns.append(column + nextCheckpoint - position)
                        nextCheckpoint += Self.checkpointBytes
                    }
                    column += chunk.byteCount
                    position = end
                }
                else {
                    for byte in chunk.bytes() {
                        guard byte == 9 || (32...126).contains(byte) else {
                            throw SourceError.unsupportedByte
                        }
                        column += Self.advance(for: byte, from: column, tabWidth: tabWidth)
                        position += 1
                        if position == nextCheckpoint {
                            columns.append(column)
                            nextCheckpoint += Self.checkpointBytes
                        }
                    }
                }
            }
        }
        catch SourceError.unsupportedByte {
            return nil
        }
        try Self.check(deadline)
        self.range = range
        self.tabWidth = tabWidth
        columnCount = column
        sourceIdentity = source.root.identity
        text = slice
        checkpoints = columns
    }

    /// 业务作用：编辑仅能复用同一不可变正文根和制表宽度的列证据，修订后的内容必须重新确认。
    /// 参数说明:
    /// - source: 当前事务所属正文。
    /// - width: 本次实际制表宽度。
    /// 返回：产生索引的原字节根和当前制表宽度均一致时为真。
    func matches(_ source: PieceTree, width: Int) -> Bool {
        sourceIdentity == source.root.identity && tabWidth == width
    }

    /// 业务作用：在已验证长行内定位实际字节端点的视觉列，只重读相邻检查点后的有限原文。
    /// 参数说明:
    /// - offset: 相对行首的正文原字节偏移，包含行尾。
    /// 返回：已证据化的视觉列，行外偏移为空。
    public func column(at offset: Int) -> Int? {
        guard (0...range.count).contains(offset) else {
            return nil
        }
        let checkpoint = offset / Self.checkpointBytes
        let bytes = text.bytes(in: ByteRange(checkpoint * Self.checkpointBytes, offset))
        return bytes.reduce(checkpoints[checkpoint]) { column, byte in
            column + Self.advance(for: byte, from: column, tabWidth: tabWidth)
        }
    }

    /// 业务作用：从可见视觉列查找真实原字节范围，Tab 内部仍定位到该字符前的实际端点。
    /// 参数说明:
    /// - column: 完整逻辑行内的视觉列，包含行尾。
    /// 返回：不越过给定列的最近原字节端点，行外视觉列为空。
    public func offset(atOrBefore column: Int) -> Int? {
        guard (0...columnCount).contains(column) else {
            return nil
        }
        var lower = 0
        var upper = checkpoints.count
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            if checkpoints[middle] <= column {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        var position = lower * Self.checkpointBytes
        var value = checkpoints[lower]
        let bytes = text.bytes(in: ByteRange(position, min(position + Self.checkpointBytes, range.count)))
        for byte in bytes {
            let advance = Self.advance(for: byte, from: value, tabWidth: tabWidth)
            guard advance <= column - value else {
                break
            }
            value += advance
            position += 1
        }
        return position
    }

    /// 业务作用：真实 Tab 对齐到下一停靠位，普通可打印 ASCII 只前进一列。
    /// 参数说明:
    /// - byte: 已验证的 ASCII 正文或真实 Tab。
    /// - column: 当前实测前缀列数。
    /// - tabWidth: 本轮固定的语言 Tab 宽度。
    /// 返回：当前字节覆盖的视觉列数。
    private static func advance(for byte: UInt8, from column: Int, tabWidth: Int) -> Int {
        byte == 9 ? tabWidth - column % tabWidth : 1
    }

    /// 业务作用：只在仍有完整测量时间及资格时读取下一分块，过期索引不行使排版授权。
    /// 参数说明:
    /// - deadline: 从测量开始固定的截止时刻。
    /// 返回：仍有时间且未取消时继续，过期或取消时不返回部分列索引。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("长行 Tab 列测量超过五秒预算。")
        }
    }
}
