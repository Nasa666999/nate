import Foundation

public struct ASCIIWordWrapIndex: Sendable {
    public let range: ByteRange
    public let columns: Int
    public let rowCount: Int
    public let maximumRowLength: Int
    public let characterCount: Int
    public let narrowScalars: [UInt16]
    public let usesFullWidthFont: Bool
    public let mixedHanMetrics: MixedHanWrapMetrics?
    private let totalHeight: Double

    private struct Anchor: Sendable {
        let row: Int
        let byte: Int
        let y: Double
    }

    enum Refusal: Error {
        case character
        case row
        case punctuation
    }

    enum Script: Equatable, Sendable {
        case ascii
        case narrow
        case han
        case mixedHan(MixedHanWrapMetrics)
        case mixedHanTabs(MixedHanWrapMetrics, HanTabColumns.Metrics, contentEnd: Int)
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
        if case .mixedHanTabs(_, let metrics, _) = script {
            return metrics.tabWidth
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

    /// 业务作用：基本汉字、已支持标点和 ASCII 词共用真实容器，每个视觉行按自身字体组成确认高度。
    /// 参数说明:
    /// - text: 当前不可变正文。
    /// - range: 排除实际换行符后的完整物理行范围。
    /// - columns: 当前基础字体的原生列数，用于确认视口身份。
    /// - source: 已证明属于同一行的汉字与 ASCII 字形范围。
    /// - metrics: 当前真实基础及级联字体的容器、步距与行高。
    /// - deadline: 所有实际断行与垂直定位共用的截止。
    /// 返回：全部字形及可用断点确认后提供索引，存在无法定位的段落语境时为空。
    public static func withMixedHan(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        source: PlainHanLine,
        metrics: MixedHanWrapMetrics,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        try mixedHanIndex(
            text: text,
            range: range,
            columns: columns,
            han: source,
            tabs: nil,
            metrics: metrics,
            deadline: deadline
        )
    }

    /// 业务作用：在已确认的中英文原字节上把真实 Tab 按每条视觉行自己的原点重新定位。
    /// 参数说明:
    /// - text: 当前不可变正文。
    /// - range: 排除物理行尾的完整逻辑行。
    /// - columns: 当前容器采用的基础字体列数。
    /// - source: 同一正文和实际语言制表间隔已证明的字符与逻辑列。
    /// - metrics: 当前真实容器的两种字体步距及行高。
    /// - deadline: 同一测量请求的完整截止。
    /// 返回：制表、标点断点及两类字体均能确认时提供完整索引，缺少原生证据时为空。
    public static func withMixedHanTabs(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        source: HanTabColumns,
        metrics: MixedHanWrapMetrics,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        try mixedHanIndex(
            text: text,
            range: range,
            columns: columns,
            han: nil,
            tabs: source,
            metrics: metrics,
            deadline: deadline
        )
    }

    /// 业务作用：有无真实制表的混排行共享标点分词与整行发布条件。
    /// 参数说明:
    /// - text: 固定的完整原正文。
    /// - range: 当前逻辑行正文的原字节范围。
    /// - columns: 当前基础字体实际列数。
    /// - han: 无制表行的完整字形证据。
    /// - tabs: 含制表行的完整字形及逻辑列证据。
    /// - metrics: 当前两种实际字体及容器度量。
    /// - deadline: 两次原生断行尝试共同遵守的截止。
    /// 返回：原位置和度量确认为同一段时提供完整索引；缺少断点或字形证据时为空。
    private static func mixedHanIndex(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        han: PlainHanLine?,
        tabs: HanTabColumns?,
        metrics: MixedHanWrapMetrics,
        deadline: ContinuousClock.Instant
    ) throws -> Self? {
        do {
            return try Self(
                text: text,
                range: range,
                columns: columns,
                narrow: nil,
                han: han,
                mixedHan: metrics,
                narrowTabs: tabs,
                deadline: deadline
            )
        }
        catch Refusal.punctuation {
            // 确认标点后须在同一截止内重算整个逻辑行，前后断点才能使用同一份分词证据。
            return try Self(
                text: text,
                range: range,
                columns: columns,
                narrow: nil,
                han: han,
                mixedHan: metrics,
                narrowTabs: tabs,
                allowsPunctuation: true,
                deadline: deadline
            )
        }
    }

    /// 业务作用：不同字体类型复用同一完整视觉行索引和有界稀疏锚点。
    /// 参数说明:
    /// - text: 当前固定的原正文。
    /// - range: 待确认的完整逻辑行原字节范围。
    /// - columns: 实际对应字体和容器的列数。
    /// - narrow: 可选的同源多字节窄字母证明。
    /// - han: 可选的同源全角字形证明。
    /// - mixedHan: 存在窄字形及全角字形时采用的实际原生度量。
    /// - tabs: 可选的同源原始 ASCII 制表证明。
    /// - narrowTabs: 可选的已确认包含独立窄字母或全角字形的同源制表证明。
    /// - allowsPunctuation: 已请求逐页解释原生可用标点断行时为真。
    /// - deadline: 准备任务的共同截止。
    /// 返回：字体类别和所有边界已经核对的完整索引，超量或非法字符时拒绝。
    private init?(
        text: PieceTree,
        range: ByteRange,
        columns: Int,
        narrow: PlainNarrowUnicodeLine?,
        han: PlainHanLine?,
        mixedHan: MixedHanWrapMetrics? = nil,
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
            guard han.range == range, han.matches(text) else {
                return nil
            }
            if let mixedHan, han.characterCount * 3 != range.count {
                script = .mixedHan(mixedHan)
            }
            else if mixedHan == nil, han.characterCount * 3 == range.count {
                script = .han
            }
            else {
                return nil
            }
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
            guard narrowTabs.range == range, narrowTabs.matches(text, tabWidth: width) else {
                return nil
            }
            if let mixedHan {
                let grid = narrowTabs.metrics
                guard narrowTabs.hasFullWidthCharacters, narrowTabs.narrowScalars.isEmpty,
                    grid.asciiAdvance == mixedHan.asciiAdvance, grid.hanAdvance == mixedHan.hanAdvance
                else {
                    return nil
                }
                let end = try Self.finalContentEnd(
                    in: text,
                    range: range,
                    includesFullwidthSpace: true,
                    deadline: deadline
                )
                script = .mixedHanTabs(mixedHan, grid, contentEnd: end)
            }
            else {
                guard !narrowTabs.hasFullWidthCharacters, !narrowTabs.narrowScalars.isEmpty else {
                    return nil
                }
                let end = try Self.finalContentEnd(in: text, range: range, deadline: deadline)
                script = .tabbed(width: width, contentEnd: end, narrowLetters: true)
            }
        }
        else {
            guard text.isPrintableASCII(in: range) else {
                return nil
            }
            script = .ascii
        }
        let punctuation: MonospaceLineBreaks?
        let fullwidthPunctuation = mixedHan != nil && han?.containsFullwidthPunctuation == true
        if allowsPunctuation || fullwidthPunctuation {
            guard
                let pages = try MonospaceLineBreaks(
                    text: text,
                    range: range,
                    allowsNarrowLetters: narrow != nil || narrowTabs != nil,
                    allowsFullwidth: mixedHan != nil,
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
        var anchors = [Anchor(row: 0, byte: range.lower, y: 0)]
        var row = 0
        var start = range.lower
        var widest = 0
        var height = 0.0
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
                    anchors.append(Anchor(row: row, byte: start, y: height))
                }
                let next = try cursor.nextRow(after: start, columns: columns)
                widest = max(widest, next.cells)
                if let mixedHan {
                    height += try Self.height(of: ByteRange(start, next.end), in: text, metrics: mixedHan)
                }
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
        mixedHanMetrics = mixedHan
        totalHeight = height
    }

    /// 业务作用：整个段落仅有一行时，原生布局允许最后的制表空白留在该行。
    /// 参数说明:
    /// - text: 当前真实制表索引所属的原文。
    /// - range: 完整物理行原字节范围。
    /// - includesFullwidthSpace: 原文已确认可含 Unicode 全角空格时为真。
    /// - deadline: 当前断行准备的共同截止。
    /// 返回：最后一个非空白字节之后的端点；全部为空白时返回行首。
    private static func finalContentEnd(
        in text: PieceTree,
        range: ByteRange,
        includesFullwidthSpace: Bool = false,
        deadline: ContinuousClock.Instant
    ) throws -> Int {
        var end = range.upper
        while end > range.lower {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("超长自动换行的尾随制表超过共同截止。")
            }
            var start = max(range.lower, end - 8192)
            if includesFullwidthSpace {
                // 从完整原标量开始扫描，尾部全角空格不会被读取分页的边界拆开。
                while !text.isBoundary(start) {
                    start += 1
                }
            }
            let bytes = text.bytes(in: ByteRange(start, end))
            var suffix = bytes.count
            while suffix > 0 {
                if bytes[suffix - 1] == 9 || bytes[suffix - 1] == 32 {
                    suffix -= 1
                }
                else if includesFullwidthSpace, suffix >= 3, bytes[suffix - 3] == 227,
                    bytes[suffix - 2] == 128, bytes[suffix - 1] == 128
                {
                    suffix -= 3
                }
                else {
                    return start + suffix
                }
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

    /// 业务作用：为混排文本的小窗口恢复完整逻辑行中的原生纵向偏移。
    /// 参数说明:
    /// - row: 完整逻辑行内的视觉行号；末行之后可取得总高。
    /// 返回：经当前字体组合确认的累计高度，固定行高或无效位置为空。
    public func variableOffset(at row: Int) -> Double? {
        guard let mixedHanMetrics, (0...rowCount).contains(row) else {
            return nil
        }
        if row == rowCount {
            return totalHeight
        }
        let anchor = anchor(at: row, by: \.row)
        var cursor = Cursor(text: text, range: range, script: script, punctuation: punctuation)
        var start = anchor.byte
        var y = anchor.y
        for _ in anchor.row..<row {
            guard let next = try? cursor.nextRow(after: start, columns: columns),
                let height = try? Self.height(
                    of: ByteRange(start, next.end),
                    in: text,
                    metrics: mixedHanMetrics
                )
            else {
                return nil
            }
            y += height
            start = next.end
        }
        return y
    }

    /// 业务作用：字体高度不同的视觉行仍沿同一原始几何定位真实可见行。
    /// 参数说明:
    /// - y: 相对完整逻辑行顶部的实际纵向像素。
    /// 返回：包含位置的视觉行；超过范围时定位到相应首尾行，非混排索引为空。
    public func variableRow(at y: Double) -> Int? {
        guard let mixedHanMetrics, y.isFinite else {
            return nil
        }
        if y >= totalHeight {
            return rowCount - 1
        }
        let anchor = anchor(at: max(0, y), by: \.y)
        var cursor = Cursor(text: text, range: range, script: script, punctuation: punctuation)
        var start = anchor.byte
        var offset = anchor.y
        for row in anchor.row..<rowCount {
            guard let next = try? cursor.nextRow(after: start, columns: columns),
                let height = try? Self.height(
                    of: ByteRange(start, next.end),
                    in: text,
                    metrics: mixedHanMetrics
                )
            else {
                return nil
            }
            if y < offset + height {
                return row
            }
            offset += height
            start = next.end
        }
        return rowCount - 1
    }

    /// 业务作用：每个已确认的混排范围按实际存在的较高字体取得真实行高。
    /// 参数说明:
    /// - row: 已完整确认的视觉行原字节范围。
    /// - text: 原不可变正文。
    /// - metrics: 同一容器和字体的真实度量。
    /// 返回：纯 ASCII 或含全角字形的真实高度，原端点无效时终止。
    private static func height(of row: ByteRange, in text: PieceTree, metrics: MixedHanWrapMetrics) throws
        -> Double
    {
        guard let positions = text.nsRange(row) else {
            throw Refusal.row
        }
        return positions.length == row.count ? metrics.asciiHeight : metrics.hanHeight
    }

    /// 业务作用：按字节、视觉行或纵坐标定位最近的已证明锚点，只读取当前需要的局部原文。
    /// 参数说明:
    /// - target: 已验证的字节、实际视觉行或原生纵坐标。
    /// - order: 目标采用的单调索引字段。
    /// 返回：不超过目标的最后一个索引锚点。
    private func anchor<Value: Comparable>(at target: Value, by order: KeyPath<Anchor, Value>) -> Anchor {
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
