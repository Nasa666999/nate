import Foundation

extension ASCIIWordWrapIndex {
    struct Cursor {
        let text: PieceTree
        let range: ByteRange
        let script: Script
        private var punctuation: MonospaceLineBreaks.Cursor?
        private var pageStart = 0
        private var page: [UInt8] = []

        /// 业务作用：视觉行只从固定的原文树读取已确认范围，查找相邻字节不会整体复制逻辑行。
        /// 参数说明:
        /// - text: 当前固定正文。
        /// - range: 原逻辑行的合法原字节范围。
        /// - script: 原文范围已确认的字形类别。
        /// - punctuation: 可用的完整原生标点分页。
        /// 返回：独立的有界读缓存。
        init(text: PieceTree, range: ByteRange, script: Script, punctuation: MonospaceLineBreaks?) {
            self.text = text
            self.range = range
            self.script = script
            self.punctuation = punctuation.map { MonospaceLineBreaks.Cursor(source: $0, text: text) }
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
            if case .tabbed(let width, let contentEnd, let narrowLetters) = script {
                return try nextTabbedRow(
                    after: start,
                    columns: columns,
                    tabWidth: width,
                    contentEnd: contentEnd,
                    narrowLetters: narrowLetters
                )
            }
            if punctuation != nil {
                return try nextPunctuationRow(after: start, columns: columns)
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

        /// 业务作用：按真实原生标点机会选择视觉行断点，保留实际可悬挂的空格及必要的强制分行。
        /// 参数说明:
        /// - start: 当前视觉行首的实际原字节偏移。
        /// - columns: 已由真实容器及等宽字体确认的普通列数。
        /// 返回：同一正文上的完整视觉行结束位置和宽度。
        private mutating func nextPunctuationRow(after start: Int, columns: Int) throws -> (
            end: Int, cells: Int
        ) {
            var limit = min(start + columns, range.upper)
            var width = limit - start
            if script == .narrow {
                // 混排字符各占一列，但可能有两个原字节，强制断行也必须走完整字符端点。
                guard let first = text.utf16Offset(byte: start),
                    let last = text.utf16Offset(byte: range.upper)
                else {
                    throw Refusal.row
                }
                width = min(columns, last - first)
                guard let bound = text.byteOffset(utf16: first + width) else {
                    throw Refusal.row
                }
                limit = bound
            }
            let trailing = try appendSpaces(after: limit, cells: width, lineStart: start, tabs: nil)
            if trailing.end == range.upper {
                return trailing
            }
            if try punctuation?.boundary(atOrBefore: trailing.end) == trailing.end {
                return trailing
            }
            let word = try punctuation?.boundary(atOrBefore: limit) ?? limit
            let end = word > start ? word : limit
            if script == .narrow {
                guard let first = text.utf16Offset(byte: start), let last = text.utf16Offset(byte: end) else {
                    throw Refusal.row
                }
                return (end, last - first)
            }
            return (end, end - start)
        }

        /// 业务作用：真实 Tab 以视觉行首为列原点，越过容器时只在实际字节边界断行。
        /// 参数说明:
        /// - start: 新视觉行的实际原字节起点。
        /// - columns: 当前容器在该字体下的普通列数。
        /// - tabWidth: 当前语言原制表宽度。
        /// - contentEnd: 完整段落最后一个非空白之后的端点。
        /// - narrowLetters: 原位置已经证明可包含完整两字节窄字母时为真。
        /// 返回：视觉行原字节终点及从该行行首得出的实际像素列数。
        private mutating func nextTabbedRow(
            after start: Int,
            columns: Int,
            tabWidth: Int,
            contentEnd: Int,
            narrowLetters: Bool
        ) throws -> (end: Int, cells: Int) {
            var position = start
            var cells = 0
            var lastBreak: (end: Int, cells: Int)?
            while position < range.upper {
                if start == range.lower, position >= contentEnd {
                    return try appendSpaces(after: position, cells: cells, lineStart: start, tabs: tabWidth)
                }
                let current = byte(at: position)
                if current == 9 {
                    let stop = cells + ASCIITabColumns.advance(for: current, from: cells, tabWidth: tabWidth)
                    if stop > columns {
                        if position == start {
                            // 制表比整行还宽时仍保留完整字节，下一视觉行重新从本行的原点排版。
                            let trailing = try appendSpaces(
                                after: position + 1,
                                cells: stop,
                                lineStart: start,
                                tabs: nil
                            )
                            return try acceptsSpaces(at: trailing.end) ? trailing : (position + 1, stop)
                        }
                        return (position, cells)
                    }
                    position += 1
                    cells = stop
                    if try acceptsBreak(at: position) {
                        lastBreak = (position, cells)
                    }
                }
                else if current == 32 {
                    if cells >= columns {
                        let trailing = try appendSpaces(
                            after: position,
                            cells: cells,
                            lineStart: start,
                            tabs: nil
                        )
                        return try acceptsSpaces(at: trailing.end) ? trailing : lastBreak ?? (position, cells)
                    }
                    position += 1
                    cells += 1
                    if try acceptsBreak(at: position) {
                        lastBreak = (position, cells)
                    }
                }
                else {
                    guard punctuation != nil || PieceNode.isASCIIAlphanumeric(current) else {
                        throw Refusal.character
                    }
                    if cells >= columns {
                        return lastBreak ?? (position, cells)
                    }
                    // 经原字符集验证的窄字母只占一列，断点不可落在 UTF-8 后续字节上。
                    position += narrowLetters && (194...223).contains(current) ? 2 : 1
                    cells += 1
                    if punctuation != nil, try acceptsBreak(at: position) {
                        lastBreak = (position, cells)
                    }
                }
            }
            return (position, cells)
        }

        /// 业务作用：标点存在时由原生断行确认当前候选，简单字母数字和空白可直接使用已知规则。
        /// 参数说明:
        /// - offset: 完整原制表或普通字节之后的实际位置。
        /// 返回：能在当前原始边界结束视觉行为真。
        private mutating func acceptsBreak(at offset: Int) throws -> Bool {
            (try punctuation?.boundary(atOrBefore: offset) ?? offset) == offset
        }

        /// 业务作用：溢出空格只留在原生允许的行尾；后续真实 Tab 自己重新计算停靠。
        /// 参数说明:
        /// - end: 紧邻空格后的原始端点。
        /// 返回：空白确实应归于当前视觉行时为真。
        private mutating func acceptsSpaces(at end: Int) throws -> Bool {
            if end == range.upper || byte(at: end) == 9 {
                return true
            }
            return try acceptsBreak(at: end)
        }

        /// 业务作用：尾随空格及整段末尾符合条件的制表留在实际视觉行中，原字节容量保持有界。
        /// 参数说明:
        /// - position: 当前尚未消费的实际原字节。
        /// - cells: 视觉行当前已占用的普通列数。
        /// - lineStart: 该视觉行用来确认字节容量的真实起点。
        /// - tabs: 允许追加制表时的完整原宽度；仅允许普通空格时为空。
        /// 返回：可追加的原字节及真实列数，容量不足时拒绝发布。
        private mutating func appendSpaces(
            after position: Int,
            cells: Int,
            lineStart: Int,
            tabs: Int?
        ) throws -> (end: Int, cells: Int) {
            var end = position
            var width = cells
            while end < range.upper {
                let value = byte(at: end)
                if value != 32, value != 9 || tabs == nil {
                    break
                }
                guard end - lineStart < ASCIIWordWrapIndex.maximumRowBytes else {
                    throw Refusal.row
                }
                width += ASCIITabColumns.advance(for: value, from: width, tabWidth: tabs ?? 1)
                end += 1
            }
            return (end, width)
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
