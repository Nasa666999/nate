import Foundation

public struct ASCIIWordWrapIndex: Sendable {
    public let range: ByteRange
    public let columns: Int
    public let rowCount: Int
    public let maximumRowLength: Int
    public let characterCount: Int
    public let narrowScalars: [UInt16]
    public let usesFullWidthFont: Bool

    private struct Anchor: Sendable {
        let row: Int
        let byte: Int
    }

    private enum Refusal: Error {
        case character
        case row
    }

    private enum Script {
        case ascii
        case narrow
        case han
    }

    private let text: PieceTree
    private let script: Script
    private let anchors: [Anchor]
    private static let anchorDistance = 4096
    private static let maximumRowBytes = 65_536

    /// 业务作用：固定等宽 ASCII 文本的真实字间断行，在接近视口的位置保留完整的原字节起点。
    /// 参数说明:
    /// - text: 已提交的不可变正文。
    /// - range: 同一正文内不含物理结束符的逻辑行。
    /// - columns: 当前容器和实际等宽字形共同确认的视觉列数。
    /// - deadline: 完整行的共同准备截止。
    /// 返回：完整的稀疏视觉行索引；非 ASCII 字母、数字或空格返回空，超限或取消拒绝全部证据。
    public init?(text: PieceTree, range: ByteRange, columns: Int, deadline: ContinuousClock.Instant) throws {
        try self.init(text: text, range: range, columns: columns, narrow: nil, deadline: deadline)
    }

    /// 业务作用：支持已确认独立窄字母的软换行，原字节、字符与视觉行的计数相互独立。
    /// 参数说明:
    /// - text: 当前提交的不可变正文。
    /// - range: 排除原始物理结束符后的完整逻辑行。
    /// - columns: 当前真实视口和实际字体确认的视觉列。
    /// - narrow: 此原文已通过的多字节窄字母证据；纯 ASCII 请求为空。
    /// - deadline: 完整原文及窗口准备共用的截止。
    /// 返回：全部原字节断点及稀疏锚点，字符、原文或容量无法确认时不发布。
    public init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        narrow: PlainNarrowUnicodeLine?,
        deadline: ContinuousClock.Instant
    ) throws {
        try self.init(
            text: text,
            range: range,
            columns: columns,
            narrow: narrow,
            han: nil,
            deadline: deadline
        )
    }

    /// 业务作用：全角汉字与明确标点采用实测级联字体的固定字形数及原始断行边界。
    /// 参数说明:
    /// - text: 当前提交的不可变正文。
    /// - range: 排除原始结束符的完整逻辑行。
    /// - columns: 当前容器和实际全角字体确认的每行字形数。
    /// - han: 同一完整原行的全角字符证据。
    /// - deadline: 全部字体范围的共同准备截止。
    /// 返回：原始字节软换行，遇到窄字形、超限或源变化时不发布部分索引。
    public init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        fullWidth han: PlainHanLine,
        deadline: ContinuousClock.Instant
    ) throws {
        try self.init(text: text, range: range, columns: columns, narrow: nil, han: han, deadline: deadline)
    }

    /// 业务作用：不同字体类型复用同一完整视觉行索引和有界稀疏锚点。
    /// 参数说明:
    /// - text: 当前固定的原正文。
    /// - range: 待确认的完整逻辑行原字节范围。
    /// - columns: 实际对应字体和容器的列数。
    /// - narrow: 可选的同源多字节窄字母证明。
    /// - han: 可选的同源全角字形证明。
    /// - deadline: 准备任务的共同截止。
    /// 返回：字体类别和所有边界已经核对的完整索引，超量或非法字符时拒绝。
    private init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        narrow: PlainNarrowUnicodeLine?,
        han: PlainHanLine?,
        deadline: ContinuousClock.Instant
    ) throws {
        guard range.lower >= 0, range.upper > range.lower, range.upper <= text.byteCount,
            range.count <= 1_073_741_824, (1...8192).contains(columns)
        else {
            return nil
        }
        let script: Script
        if let han {
            // 只有整行字形都由同一个全角字体提供时，才可按固定视觉列计算断点。
            guard han.range == range, han.matches(text), han.characterCount * 3 == range.count else {
                return nil
            }
            script = .han
        }
        else if let narrow {
            guard narrow.range == range, narrow.matches(text) else {
                return nil
            }
            script = .narrow
        }
        else {
            guard text.isPrintableASCII(in: range) else {
                return nil
            }
            script = .ascii
        }
        var cursor = Cursor(text: text, range: range, script: script)
        var anchors = [Anchor(row: 0, byte: range.lower)]
        var row = 0
        var start = range.lower
        var widest = 0
        do {
            repeat {
                // 全部逻辑行先完成并确认仍属同一次计算，才交给主线程用于远端导航。
                if row & 127 == 0 {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else {
                        throw NateError.message("超长自动换行的原字节索引超过共同截止。")
                    }
                }
                if start - anchors[anchors.count - 1].byte >= Self.anchorDistance {
                    anchors.append(Anchor(row: row, byte: start))
                }
                let next = try cursor.nextRow(after: start, columns: columns)
                widest = max(widest, next.cells)
                start = next.end
                row += 1
            } while start < range.upper
        }
        catch Refusal.character {
            return nil
        }
        catch Refusal.row {
            throw NateError.message("超长自动换行的单个视觉行超过 65536 个原字节。")
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("超长自动换行的原字节索引超过共同截止。")
        }
        self.text = text
        self.script = script
        self.range = range
        self.columns = columns
        self.anchors = anchors
        rowCount = row
        maximumRowLength = widest
        characterCount = han?.characterCount ?? narrow?.characterCount ?? range.count
        narrowScalars = narrow?.scalars ?? []
        usesFullWidthFont = script == .han
    }

    /// 业务作用：不同修订、排版宽度或正文根不能使用另一份视觉行范围。
    /// 参数说明:
    /// - text: 当前视图使用的原正文。
    /// - columns: 视口重新确认的实际列数。
    /// 返回：当前宽度及来源均匹配时为真。
    public func matches(_ text: PieceTree, columns: Int) -> Bool {
        self.columns == columns && self.text.sourceIdentity == text.sourceIdentity
    }

    /// 业务作用：从最近已确认的视觉行起点恢复原位置，无需从长行开端重新扫描。
    /// 参数说明:
    /// - byte: 当前完整逻辑行内的原字节插入端点。
    /// - downstream: 是否采用断点之后的视觉行，文件行尾始终属于最后一个视觉行。
    /// 返回：实际视觉行号；原字节越界或证据不足时为空。
    public func row(at byte: Int, downstream: Bool) -> Int? {
        guard range.lower <= byte, byte <= range.upper, script == .ascii || text.isBoundary(byte) else {
            return nil
        }
        let target = max(range.lower, min(range.upper - 1, downstream ? byte : byte - 1))
        let anchor = anchor(at: target, by: \.byte)
        var row = anchor.row
        var start = anchor.byte
        var cursor = Cursor(text: text, range: range, script: script)
        while let next = try? cursor.nextRow(after: start, columns: columns) {
            if target < next.end {
                return row
            }
            start = next.end
            row += 1
        }
        return nil
    }

    /// 业务作用：生成附近的完整视觉行，调用方可按原字节容量裁剪至实际渲染窗口。
    /// 参数说明:
    /// - row: 请求的起始真实视觉行号。
    /// - count: 请求的连续视觉行数，最多 4096。
    /// 返回：该窗口的完整原始范围，越界或计算失败时为空。
    public func rows(startingAt row: Int, count: Int) -> [ByteRange]? {
        guard row >= 0, (1...4096).contains(count), row < rowCount, count <= rowCount - row else {
            return nil
        }
        let anchor = anchor(at: row, by: \.row)
        var cursor = Cursor(text: text, range: range, script: script)
        var start = anchor.byte
        var output: [ByteRange] = []
        output.reserveCapacity(count)
        for current in anchor.row..<(row + count) {
            guard let next = try? cursor.nextRow(after: start, columns: columns) else {
                return nil
            }
            if current >= row {
                output.append(ByteRange(start, next.end))
            }
            start = next.end
        }
        return output
    }

    /// 业务作用：按字节或视觉行定位最近的已证明锚点，只读取当前需要的局部原文。
    /// 参数说明:
    /// - target: 已验证的字节或视觉行。
    /// - order: 采用真实字节或实际视觉行作为单调索引。
    /// 返回：不超过目标的最后一个索引锚点。
    private func anchor(at target: Int, by order: KeyPath<Anchor, Int>) -> Anchor {
        var lower = 0
        var upper = anchors.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if anchors[middle][keyPath: order] <= target {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        return anchors[lower]
    }
}

extension ASCIIWordWrapIndex {
    private struct Cursor {
        let text: PieceTree
        let range: ByteRange
        let script: Script
        private var pageStart = 0
        private var page: [UInt8] = []

        /// 业务作用：视觉行只从固定的原文树读取已确认范围，查找相邻字节不会整体复制逻辑行。
        /// 参数说明:
        /// - text: 当前固定正文。
        /// - range: 原逻辑行的合法原字节范围。
        /// - script: 原文范围已确认的字形类别。
        /// 返回：独立的有界读缓存。
        init(text: PieceTree, range: ByteRange, script: Script) {
            self.text = text
            self.range = range
            self.script = script
        }

        /// 业务作用：按实际等宽软换行规则分隔独立单词和尾随空格，过长单词按原字节边界分段。
        /// 参数说明:
        /// - start: 前一实际视觉行已确认的结束端点。
        /// - columns: 当前字体和容器的固定列数。
        /// 返回：下一处原始视觉行端点，缺少字符资格或单行预算时终止。
        mutating func nextRow(after start: Int, columns: Int) throws -> (end: Int, cells: Int) {
            guard start < range.upper else {
                throw Refusal.row
            }
            if script == .han {
                return try nextHanRow(after: start, columns: columns)
            }
            var position = start
            var cells = 0
            var lastSpace: (end: Int, cells: Int)?
            while position < range.upper, cells < columns {
                let scalar = byte(at: position)
                cells += 1
                if scalar == 32 {
                    position += 1
                    lastSpace = (position, cells)
                }
                else if PieceNode.isASCIIAlphanumeric(scalar) {
                    position += 1
                }
                else if script == .narrow, (194...223).contains(scalar) {
                    // 两字节独立窄字母已由同一原文的标量证据确认，不能在 UTF-8 内切开视觉行。
                    position += 2
                }
                else {
                    throw Refusal.character
                }
            }
            guard position < range.upper else {
                return (position, cells)
            }
            guard byte(at: position) == 32 else {
                return lastSpace ?? (position, cells)
            }
            // 原生段落将断点后的连续空格视为前一视觉行的尾部，不能把这些原字节移到下一行。
            repeat {
                guard position - start < ASCIIWordWrapIndex.maximumRowBytes else {
                    throw Refusal.row
                }
                position += 1
                cells += 1
            } while position < range.upper && byte(at: position) == 32
            return (position, cells)
        }

        private static let opens = Set("〈《「『【〔（［｛".utf16)
        private static let cannotStart = Set("、。〉》」』】〕！），：；？］｝　".utf16)

        /// 业务作用：保留全角行首和行尾标点约束，容器不足时按实际完整字形强制断行。
        /// 参数说明:
        /// - start: 上一视觉行已确认的实际原字节边界。
        /// - columns: 已确认的全角字体单行容量。
        /// 返回：下一视觉行真实端点及前一行占用的 UTF-16 单元数。
        private mutating func nextHanRow(after start: Int, columns: Int) throws -> (end: Int, cells: Int) {
            let hard = min(range.upper, start + columns * 3)
            guard hard < range.upper else {
                return (hard, (hard - start) / 3)
            }
            var previous = hanScalar(at: start)
            var valid: Int?
            for boundary in stride(from: start + 3, through: hard, by: 3) {
                let following = hanScalar(at: boundary)
                if !Self.opens.contains(previous), !Self.cannotStart.contains(following) {
                    valid = boundary
                }
                previous = following
            }
            if previous == 0x3000 {
                // 真实 TextKit 只在空白后的下一个字符允许行首时，把溢出的全角空白归到前一行。
                var end = hard
                while end < range.upper, hanScalar(at: end) == 0x3000 {
                    guard end - start <= ASCIIWordWrapIndex.maximumRowBytes - 3 else {
                        throw Refusal.row
                    }
                    end += 3
                }
                if end == range.upper || !Self.cannotStart.contains(hanScalar(at: end)) {
                    return (end, (end - start) / 3)
                }
            }
            let end = valid ?? hard
            return (end, (end - start) / 3)
        }

        /// 业务作用：直接在同源 UTF-8 中取得已证明的完整三字节全角标量。
        /// 参数说明:
        /// - offset: 完整原标量的起点。
        /// 返回：可完整参与标点约束的单个 BMP 标量。
        private mutating func hanScalar(at offset: Int) -> UInt16 {
            let first = UInt16(byte(at: offset) & 15)
            let second = UInt16(byte(at: offset + 1) & 63)
            let third = UInt16(byte(at: offset + 2) & 63)
            return (first << 12) | (second << 6) | third
        }

        /// 业务作用：读取同源的原字节，独立窄字母可能跨越局部读取缓存。
        /// 参数说明:
        /// - offset: 当前逻辑行内的真实原字节偏移。
        /// 返回：同一固定正文在指定有效位置的原字节。
        private mutating func byte(at offset: Int) -> UInt8 {
            if offset < pageStart || offset - pageStart >= page.count {
                pageStart = offset - (offset - range.lower) % 8192
                let end = min(range.upper, pageStart + 8192)
                page = text.bytes(in: ByteRange(pageStart, end))
            }
            return page[offset - pageStart]
        }
    }
}
