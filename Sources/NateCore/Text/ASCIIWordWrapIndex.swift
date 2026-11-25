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

    enum Refusal: Error {
        case character
        case row
    }

    enum Script: Equatable, Sendable {
        case ascii
        case narrow
        case han
        case tabbed(width: Int, contentEnd: Int, narrowLetters: Bool)
    }

    private let text: PieceTree
    private let script: Script
    private let punctuation: MonospaceLineBreaks?
    private let anchors: [Anchor]
    private static let anchorDistance = 4096
    static let maximumRowBytes = 65_536

    /// 业务作用：实际制表视觉行沿同一语言设置取得原生像素网格。
    /// 参数说明: 无。
    /// 返回：原制表宽度；其它字形范围为空。
    public var tabWidth: Int? {
        if case .tabbed(let width, _, _) = script {
            return width
        }
        return nil
    }

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

    /// 业务作用：为 ASCII 字母数字和真正的 Tab 保留每个视觉行的完整原始断点。
    /// 参数说明:
    /// - text: 当前提交的不可变正文。
    /// - range: 排除实际结束符后的完整逻辑行。
    /// - columns: 当前真实容器及原生字体提供的普通列数。
    /// - tabs: 已确认同一原文及当前语言制表宽度的索引。
    /// - deadline: 制表与视觉断行准备共用的截止。
    /// 返回：完整的视觉行字节坐标；出现其它字符、源失配或超限时拒绝。
    public init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        tabs: ASCIITabColumns,
        deadline: ContinuousClock.Instant
    ) throws {
        try self.init(
            text: text,
            range: range,
            columns: columns,
            narrow: nil,
            han: nil,
            tabs: tabs,
            deadline: deadline
        )
    }

    /// 业务作用：可打印 ASCII 的普通标点采用系统分词器的实际断行，范围超过有界分页时须有明确自然边界。
    /// 参数说明:
    /// - text: 当前已提交的不可变正文。
    /// - range: 完整物理行排除真实换行后的原始字节范围。
    /// - columns: 由当前容器与实际等宽字体共同确认的视觉列数。
    /// - tabs: 含真实制表时提供同一原文及当前语言制表宽度的完整索引。
    /// - deadline: 本次完整断行准备的共享截止。
    /// 返回：全部真实原字节断点及就近查询索引，无法得到完整原生分页时为空。
    public static func withASCIIPunctuation(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        tabs: ASCIITabColumns? = nil,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        try Self(
            text: text,
            range: range,
            columns: columns,
            narrow: nil,
            han: nil,
            tabs: tabs,
            allowsPunctuation: true,
            deadline: deadline
        )
    }

    /// 业务作用：等宽标点可与实际确认的窄字母混排，断行始终定位到完整 UTF-8 字符边界。
    /// 参数说明:
    /// - text: 当前已提交的不可变正文。
    /// - range: 整个物理行排除实际换行后的原字节范围。
    /// - columns: 当前等宽字体与容器确认的完整字形列数。
    /// - narrow: 同一原文的独立窄字母集合和字节位置证明。
    /// - deadline: 所有原生断行和坐标准备共用的截止。
    /// 返回：原生分词页、均匀视觉列数与原字节完整对应时发布索引。
    public static func withNarrowPunctuation(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        narrow: PlainNarrowUnicodeLine,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        try Self(
            text: text,
            range: range,
            columns: columns,
            narrow: narrow,
            han: nil,
            allowsPunctuation: true,
            deadline: deadline
        )
    }

    /// 业务作用：窄字母、ASCII 标点与真实 Tab 混排时保留各视觉行的制表原点及原文断点。
    /// 参数说明:
    /// - text: 当前已提交的不可变正文。
    /// - range: 排除换行符后的完整原字节范围。
    /// - columns: 实际容器与等宽字体测得的完整列数。
    /// - tabs: 同一原文的混排制表证据，范围必须只有独立窄字形。
    /// - deadline: 原字节、断行与制表索引共享的截止。
    /// 返回：全部视觉行确认后发布；包含全角字符或来源不一致时不建立索引。
    public static func withNarrowTabs(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        tabs: HanTabColumns,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        try Self(
            text: text,
            range: range,
            columns: columns,
            narrow: nil,
            han: nil,
            narrowTabs: tabs,
            allowsPunctuation: true,
            deadline: deadline
        )
    }

    /// 业务作用：不同字体类型复用同一完整视觉行索引和有界稀疏锚点。
    /// 参数说明:
    /// - text: 当前固定的原正文。
    /// - range: 待确认的完整逻辑行原字节范围。
    /// - columns: 实际对应字体和容器的列数。
    /// - narrow: 可选的同源多字节窄字母证明。
    /// - han: 可选的同源全角字形证明。
    /// - tabs: 可选的同源原始 ASCII 制表证明。
    /// - narrowTabs: 可选的包含独立窄字母的同源制表证明。
    /// - allowsPunctuation: 已请求逐页解释原生 ASCII 标点断行时为真。
    /// - deadline: 准备任务的共同截止。
    /// 返回：字体类别和所有边界已经核对的完整索引，超量或非法字符时拒绝。
    private init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        narrow: PlainNarrowUnicodeLine?,
        han: PlainHanLine?,
        tabs: ASCIITabColumns? = nil,
        narrowTabs: HanTabColumns? = nil,
        allowsPunctuation: Bool = false,
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
        else if let tabs {
            guard tabs.range == range, tabs.matches(text, width: tabs.tabWidth) else {
                return nil
            }
            let end = try Self.finalContentEnd(in: text, range: range, deadline: deadline)
            script = .tabbed(width: tabs.tabWidth, contentEnd: end, narrowLetters: false)
        }
        else if let narrowTabs {
            let width = narrowTabs.metrics.tabWidth
            guard narrowTabs.range == range, narrowTabs.matches(text, tabWidth: width),
                !narrowTabs.hasFullWidthCharacters, !narrowTabs.narrowScalars.isEmpty
            else {
                return nil
            }
            let end = try Self.finalContentEnd(in: text, range: range, deadline: deadline)
            script = .tabbed(width: width, contentEnd: end, narrowLetters: true)
        }
        else {
            guard text.isPrintableASCII(in: range) else {
                return nil
            }
            script = .ascii
        }
        let punctuation: MonospaceLineBreaks?
        if allowsPunctuation {
            guard
                let pages = try MonospaceLineBreaks(
                    text: text,
                    range: range,
                    allowsNarrowLetters: narrow != nil || narrowTabs != nil,
                    deadline: deadline
                )
            else {
                return nil
            }
            punctuation = pages
        }
        else {
            punctuation = nil
        }
        var cursor = Cursor(text: text, range: range, script: script, punctuation: punctuation)
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
        self.punctuation = punctuation
        self.range = range
        self.columns = columns
        self.anchors = anchors
        rowCount = row
        maximumRowLength = widest
        characterCount =
            han?.characterCount ?? narrow?.characterCount ?? narrowTabs?.characterCount ?? range.count
        narrowScalars = narrow?.scalars ?? narrowTabs?.narrowScalars ?? []
        usesFullWidthFont = script == .han
    }

    /// 业务作用：整个段落仅有一行时，原生布局允许最后的制表空白留在该行。
    /// 参数说明:
    /// - text: 当前真实制表索引所属的原文。
    /// - range: 完整物理行原字节范围。
    /// - deadline: 当前断行准备的共同截止。
    /// 返回：最后一个非空白字节之后的端点；全部为空白时返回行首。
    private static func finalContentEnd(
        in text: PieceTree,
        range: ByteRange,
        deadline: ContinuousClock.Instant
    ) throws -> Int {
        var end = range.upper
        while end > range.lower {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("超长自动换行的尾随制表超过共同截止。")
            }
            let start = max(range.lower, end - 8192)
            let bytes = text.bytes(in: ByteRange(start, end))
            if let last = bytes.lastIndex(where: {
                $0 != 9 && $0 != 32
            }) {
                return start + last + 1
            }
            end = start
        }
        return range.lower
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
        var cursor = Cursor(text: text, range: range, script: script, punctuation: punctuation)
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
        var cursor = Cursor(text: text, range: range, script: script, punctuation: punctuation)
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
