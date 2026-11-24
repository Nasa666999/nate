import Foundation

public struct HanTabColumns: Sendable {
    public struct Metrics: Sendable, Equatable {
        public let asciiAdvance: Double
        public let hanAdvance: Double
        public let tabWidth: Int

        /// 业务作用：测量汉字与真实 Tab 的同一原生字体和停靠间隔，不从原字节数估计像素。
        /// 参数说明:
        /// - asciiAdvance: 当前字体实测的一个普通 ASCII 的横向距离。
        /// - hanAdvance: 当前级联字体实测的一个全角字符的横向距离。
        /// - tabWidth: 当前语言实际配置的 Tab 列数。
        /// 返回：两种距离、制表间隔均有限并适合最大正文时建立度量。
        public init?(asciiAdvance: Double, hanAdvance: Double, tabWidth: Int) {
            guard (0.015625...4096).contains(asciiAdvance), (0.015625...4096).contains(hanAdvance),
                (1...32).contains(tabWidth)
            else {
                return nil
            }
            self.asciiAdvance = asciiAdvance
            self.hanAdvance = hanAdvance
            self.tabWidth = tabWidth
        }

        /// 业务作用：原生窗口满足当前语言制表停靠的同一完整坐标格。
        /// 参数说明: 无。
        /// 返回：实际原生 Tab 距离。
        public var interval: Double {
            Double(tabWidth) * asciiAdvance
        }
    }

    private struct Cursor: Sendable {
        var byte = 0
        var character = 0
        var logical = 0
        var tabStop = 0
        var ascii = 0
        var han = 0

        /// 业务作用：像素从上一真实停靠位与连续两类字形求得，避免逐字加法在远端累积误差。
        /// 参数说明:
        /// - metrics: 当前索引及 TextKit 2 共用的已确认度量。
        /// 返回：正文行首到实际字符端点的横向距离。
        func distance(using metrics: Metrics) -> Double {
            Double(tabStop) * metrics.interval
                + Double(ascii) * metrics.asciiAdvance + Double(han) * metrics.hanAdvance
        }

        /// 业务作用：有界窗口能沿同一整个物理行的网格继续排版，保留开始位置相对上一停靠位的偏量。
        /// 参数说明:
        /// - metrics: 当前确切的字体步距和制表规则。
        /// 返回：经过相邻网格定位的原生段落起始偏量。
        func phase(using metrics: Metrics) -> Double {
            remainder(using: metrics).truncatingRemainder(dividingBy: metrics.interval)
        }

        /// 业务作用：取得最后完整 ASCII 制表组之后的实际剩余宽度，纯 ASCII 整数列不会受浮点整除影响。
        /// 参数说明:
        /// - metrics: 当前有效的两类字形宽度及 Tab 间隔。
        /// 返回：不含已确认整组 ASCII 距离的原始宽度。
        private func remainder(using metrics: Metrics) -> Double {
            Double(ascii % metrics.tabWidth) * metrics.asciiAdvance + Double(han) * metrics.hanAdvance
        }

        /// 业务作用：Tab 分别使用实际原生像素间距和抽象逻辑列，保持所有正文位置与原字节相互关联。
        /// 参数说明:
        /// - scalar: 已验证范围内的实际单字节 ASCII、Tab、双字节窄字母或三字节全角字符首字节。
        /// - metrics: 当前明确配置及实测字体宽度。
        /// 返回：推进一个完整字符和两个各自正确的制表坐标。
        mutating func advance(_ scalar: UInt8, using metrics: Metrics) {
            if scalar != 9, scalar < 128 {
                addASCII(1)
                return
            }
            if (194...223).contains(scalar) {
                addASCII(1)
                byte += 1
                return
            }
            character += 1
            if scalar == 9 {
                let relative = remainder(using: metrics) / metrics.interval
                tabStop += ascii / metrics.tabWidth + Int(relative.rounded(.down)) + 1
                ascii = 0
                han = 0
                byte += 1
                logical += metrics.tabWidth - logical % metrics.tabWidth
            }
            else {
                han += 1
                byte += 3
                logical += 1
            }
        }

        /// 业务作用：不可变树已证明的纯可打印 ASCII 区间可直接推进，长前缀无需逐字确定字符类型。
        /// 参数说明:
        /// - count: 当前已确认的连续 ASCII 数量。
        /// 返回：原字节、逻辑列与像素计数共享相同前缀。
        mutating func addASCII(_ count: Int) {
            character += count
            ascii += count
            byte += count
            logical += count
        }
    }

    public let range: ByteRange
    public let metrics: Metrics
    public let characterCount: Int
    public let logicalColumnCount: Int
    public let width: Double
    public let hasFullWidthCharacters: Bool
    public let narrowScalars: [UInt16]
    private let sourceIdentity: UUID
    private let text: PieceTree
    private let checkpoints: [Cursor]
    private static let interval = 2048

    private enum UnsupportedText: Error {
        case scalar
    }

    /// 业务作用：在源可证、字体实测时为混合真实 Tab 的长行准备稀疏字节、像素与逻辑制表坐标。
    /// 参数说明:
    /// - source: 当前完整不可变正文。
    /// - range: 已确认的完整逻辑行范围，排除结束符。
    /// - metrics: 此视图实际测得的字体及当前语言 Tab 设置。
    /// - deadline: 所有前置尝试与本次测量共用的截止。
    /// 返回：包含受支持多字节文字和真实 Tab 的完整索引；未知文字、取消或超限不交付部分索引。
    public init?(
        text source: PieceTree,
        range: ByteRange,
        metrics: Metrics,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws {
        try self.init(
            text: source,
            range: range,
            metrics: metrics,
            permitsFullWidthCharacters: true,
            deadline: deadline
        )
    }

    /// 业务作用：视图只有确认全角字体后才允许原文中的全角字形参与制表估算。
    /// 参数说明:
    /// - source: 当前完整不可变正文。
    /// - range: 已确认的完整逻辑行范围，排除结束符。
    /// - metrics: 此视图实际测得的字体及当前语言 Tab 设置。
    /// - permitsFullWidthCharacters: 当前字体已确认可用的全角步距时为真。
    /// - deadline: 所有前置尝试与本次测量共用的截止。
    /// 返回：原文、逻辑列、实际宽度及原字符集的完整证据，任一条件缺失时返回空或终止。
    public init?(
        text source: PieceTree,
        range: ByteRange,
        metrics: Metrics,
        permitsFullWidthCharacters: Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        guard range.lower >= 0, range.lower < range.upper, range.count <= ASCIITabColumns.maximumBytes,
            source.isBoundary(range.lower), source.isBoundary(range.upper)
        else {
            return nil
        }
        let slice = try source.slicing(range)
        guard slice.byteCount > slice.utf16Count else {
            return nil
        }
        var cursor = Cursor()
        var checkpoints = [cursor]
        var foundHan = false
        var foundTab = false
        var narrow: Set<UInt16> = []
        checkpoints.reserveCapacity(1 + slice.utf16Count / Self.interval)
        do {
            try slice.forEachChunk(maximumBytes: 65_536) { chunk in
                try Self.requireTime(until: deadline)
                if chunk.tree.isPrintableASCII(in: ByteRange(0, chunk.byteCount)) {
                    var remaining = chunk.byteCount
                    while remaining > 0 {
                        let count = min(remaining, Self.interval - cursor.character % Self.interval)
                        cursor.addASCII(count)
                        remaining -= count
                        if cursor.character.isMultiple(of: Self.interval) {
                            checkpoints.append(cursor)
                        }
                    }
                    return
                }
                let bytes = chunk.bytes()
                var index = 0
                while index < bytes.count {
                    let byte = bytes[index]
                    let size: Int
                    if byte == 9 || (32...126).contains(byte) {
                        size = 1
                        foundTab = foundTab || byte == 9
                    }
                    else if (194...223).contains(byte), index + 1 < bytes.count {
                        let scalar = UInt16(byte & 31) << 6 | UInt16(bytes[index + 1] & 63)
                        guard PlainNarrowUnicodeLine.contains(scalar) else {
                            throw UnsupportedText.scalar
                        }
                        size = 2
                        narrow.insert(scalar)
                    }
                    else {
                        // 文本树已确认 UTF-8 的标量分块；只有与汉字字体共用实测步距的三字节字符可进入窗口。
                        guard permitsFullWidthCharacters, (227...233).contains(byte) || byte == 239,
                            index + 2 < bytes.count
                        else {
                            throw UnsupportedText.scalar
                        }
                        let scalar =
                            (UInt16(byte & 15) << 12)
                            | (UInt16(bytes[index + 1] & 63) << 6) | UInt16(bytes[index + 2] & 63)
                        guard PlainHanLine.usesHanFont(scalar) else {
                            throw UnsupportedText.scalar
                        }
                        size = 3
                        foundHan = true
                    }
                    cursor.advance(byte, using: metrics)
                    if cursor.character.isMultiple(of: Self.interval) {
                        checkpoints.append(cursor)
                    }
                    index += size
                }
            }
        }
        catch UnsupportedText.scalar {
            return nil
        }
        try Self.requireTime(until: deadline)
        guard foundHan || !narrow.isEmpty, foundTab else {
            return nil
        }
        self.range = range
        self.metrics = metrics
        characterCount = cursor.character
        logicalColumnCount = cursor.logical
        width = cursor.distance(using: metrics)
        hasFullWidthCharacters = foundHan
        narrowScalars = narrow.sorted()
        sourceIdentity = source.root.identity
        text = slice
        self.checkpoints = checkpoints
    }

    /// 业务作用：布局或编辑权限只沿本索引的真实正文根和实际制表设置延续。
    /// 参数说明:
    /// - source: 当前编辑或呈现的原文。
    /// - tabWidth: 当前语言用于实际操作的真实制表宽度。
    /// 返回：原文与配置都一致时为真。
    public func matches(_ source: PieceTree, tabWidth: Int) -> Bool {
        source.root.identity == sourceIdentity && metrics.tabWidth == tabWidth
    }

    /// 业务作用：原生投影使用严格 UTF-16 到 UTF-8 映射，窗口边缘不能截断全角字符。
    /// 参数说明:
    /// - character: 相对行首的完整 UTF-16 端点。
    /// 返回：原文绝对位置，行外为空。
    public func byte(at character: Int) -> Int? {
        text.byteOffset(utf16: character).map { range.lower + $0 }
    }

    /// 业务作用：横向滚动及实际视口切片使用同一完整行距离和原生段落起始偏量。
    /// 参数说明:
    /// - character: 已确认行内的真实 UTF-16 端点。
    /// 返回：距行首像素和局部原生起始偏量；端点无效为空。
    public func geometry(at character: Int) -> (distance: Double, phase: Double)? {
        guard let cursor = cursor(at: character) else {
            return nil
        }
        return (cursor.distance(using: metrics), cursor.phase(using: metrics))
    }

    /// 业务作用：用原始字节制表坐标截取远处窗口，Tab 内仍指向其前的真实端点。
    /// 参数说明:
    /// - x: 完整行范围内的实际横坐标。
    /// 返回：不越过指定像素的 UTF-16 端点，非法坐标为空。
    public func character(atOrBefore x: Double) -> Int? {
        guard x.isFinite, (0...width).contains(x) else {
            return nil
        }
        return cursor(atOrBefore: x) { $0.distance(using: metrics) }.character
    }

    /// 业务作用：空格 Tab 和退 Tab 使用抽象逻辑列，与实际显示字体宽度独立。
    /// 参数说明:
    /// - offset: 相对完整逻辑行首的原字节端点。
    /// 返回：对应的准确逻辑列；标量中间和行外为空。
    public func column(at offset: Int) -> Int? {
        guard let index = text.utf16Offset(byte: offset) else {
            return nil
        }
        return cursor(at: index)?.logical
    }

    /// 业务作用：由逻辑制表列取得实际可编辑端点，已有 Tab 的内部仍属于 Tab 前位置。
    /// 参数说明:
    /// - column: 从逻辑行首起算的合法抽象列。
    /// 返回：最后一个未越过该列的相对原字节，行外为空。
    public func offset(atOrBefore column: Int) -> Int? {
        guard (0...logicalColumnCount).contains(column) else {
            return nil
        }
        return cursor(atOrBefore: Double(column)) { Double($0.logical) }.byte
    }

    /// 业务作用：只重读一个稀疏索引分块，恢复真实前缀点的三种坐标。
    /// 参数说明:
    /// - index: 已验证行内的真实 UTF-16 偏移。
    /// 返回：这一处完整原字节、逻辑列和像素计数；行外为空。
    private func cursor(at index: Int) -> Cursor? {
        guard let end = text.byteOffset(utf16: index) else {
            return nil
        }
        var cursor = checkpoints[index / Self.interval]
        let start = cursor.byte
        let bytes = text.bytes(in: ByteRange(start, end))
        while cursor.byte < end {
            cursor.advance(bytes[cursor.byte - start], using: metrics)
        }
        return cursor
    }

    /// 业务作用：像素与逻辑列共用稀疏有序检查点，两种查询都不顺序重读完整前缀。
    /// 参数说明:
    /// - target: 当前已确认在合法坐标区间内的位置。
    /// - value: 从原始游标证据读取像素或逻辑列的映射。
    /// 返回：不越过该值的最后一个真实端点。
    private func cursor(atOrBefore target: Double, value: (Cursor) -> Double) -> Cursor {
        var lower = 0, upper = checkpoints.count
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            if value(checkpoints[middle]) <= target {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        var cursor = checkpoints[lower]
        let start = cursor.byte
        let end = upper < checkpoints.count ? checkpoints[upper].byte : range.count
        let bytes = text.bytes(in: ByteRange(start, end))
        while cursor.byte < end {
            var next = cursor
            next.advance(bytes[cursor.byte - start], using: metrics)
            guard value(next) <= target else {
                break
            }
            cursor = next
        }
        return cursor
    }

    /// 业务作用：有界布局后台工作只在整行证据仍有效时继续，过期不交付半个映射。
    /// 参数说明:
    /// - deadline: 该真实逻辑行所有尝试的共同截止。
    /// 返回：有效时继续，取消或超时明确退出。
    private static func requireTime(until deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("汉字长行的制表列测量超过五秒预算。")
        }
    }
}
