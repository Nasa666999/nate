import NateCore

struct PascalIndentationLine {
    private typealias Event = PascalIndentationState.Event

    private struct Span {
        let range: Range<Int>
        let event: Event
        let hasOnlySpaceBefore: Bool
    }

    private let base: Int
    private let byteCount: Int
    private let prefix: String
    private let spans: [Span]
    private let opaque: [Range<Int>]
    private let endsOpaque: Bool

    /// 业务作用：从 Pascal 原生类别提取结构事件并保留原字节范围，注释、字面和转义名称不能冒充关键词。
    /// 参数说明:
    /// - raw: 不含结束符的完整原始物理行。
    /// - base: 当前物理行在固定正文中的起点。
    /// - tokens: 同一行的完整原生类别。
    /// - startsInDirective: 当前行从上一个物理行承接了编译指令。
    /// - endsOpaque: 行末仍有不透明的词法状态，包括行注释与未结束的字面。
    /// - check: 当前输入共同使用的取消及截止检查。
    /// 返回：从行首到行尾依次排列的结构与屏蔽范围；资格撤销时不交付部分行。
    init(
        raw: [UInt8],
        base: Int,
        tokens: [SyntaxToken],
        startsInDirective: Bool,
        endsOpaque: Bool,
        check: () throws -> Void
    ) throws {
        self.base = base
        self.endsOpaque = endsOpaque
        byteCount = raw.count
        var prefixEnd = 0
        while prefixEnd < raw.count, Self.isSpace(raw[prefixEnd]) {
            if prefixEnd & 255 == 0 {
                try check()
            }
            prefixEnd += 1
        }
        prefix = String(decoding: raw[..<prefixEnd], as: UTF8.self)
        var spans: [Span] = []
        var opaque: [Range<Int>] = []
        var onlySpace = true
        for token in tokens {
            try check()
            let lower = token.range.lower - base
            let upper = min(raw.count, token.range.upper - base)
            guard lower < upper else {
                continue
            }
            let style = token.lexicalStyle
            let directive = style == "pascal:5" || style == "pascal:6"
            if token.isStructureOpaque || directive {
                opaque.append(lower..<upper)
            }
            if directive {
                var index = lower
                let brace = style == "pascal:5"
                while index < upper {
                    try check()
                    if !(index == 0 && startsInDirective),
                        let name = Self.conditionStart(at: index, in: raw, before: upper)
                    {
                        guard spans.count < 65_536 else {
                            throw NateError.message("Pascal 行缩进超过 65536 个结构事件。")
                        }
                        spans.append(
                            Span(range: index..<name, event: .directive, hasOnlySpaceBefore: onlySpace)
                        )
                    }
                    // 原生指令不嵌套，同一类别里的字面开端只能在实际关闭之后建立下一条指令。
                    while index < upper {
                        if index & 255 == 0 {
                            try check()
                        }
                        if brace && raw[index] == 125 {
                            index += 1
                            break
                        }
                        if !brace && index + 1 < upper && raw[index] == 42 && raw[index + 1] == 41 {
                            index += 2
                            break
                        }
                        index += 1
                    }
                }
                onlySpace = false
                continue
            }
            if token.kind == .comment {
                onlySpace = false
                continue
            }
            var index = lower
            while index < upper {
                if Self.isSpace(raw[index]) && (style == "pascal:0" || style == "pascal:14") {
                    if index & 255 == 0 {
                        try check()
                    }
                    index += 1
                    continue
                }
                guard spans.count < 65_536 else {
                    throw NateError.message("Pascal 行缩进超过 65536 个结构事件。")
                }
                try check()
                let end: Int
                let event: Event
                if style == "pascal:9" {
                    end = upper
                    if upper - index <= 13, (index == 0 || raw[index - 1] != 38),
                        let word = PascalIndentationState.Keyword(
                            rawValue: String(
                                decoding: raw[index..<upper].map(PascalCharacters.folded),
                                as: UTF8.self
                            )
                        )
                    {
                        event = .keyword(word)
                    }
                    else {
                        event = .other
                    }
                }
                else if style == "pascal:13" {
                    end = index + 1
                    switch raw[index] {
                    case 40, 41, 91, 93:
                        event = .grouping(raw[index])
                    case 59:
                        event = .terminator
                    case 46:
                        event = .period
                    default:
                        event = .other
                    }
                }
                else {
                    var stop = index + 1
                    while style == "pascal:0", stop < upper, !Self.isSpace(raw[stop]) {
                        if stop & 255 == 0 {
                            try check()
                        }
                        stop += 1
                    }
                    end = style == "pascal:0" ? stop : upper
                    event = .other
                }
                spans.append(Span(range: index..<end, event: event, hasOnlySpaceBefore: onlySpace))
                onlySpace = true
                index = end
            }
        }
        self.spans = spans
        self.opaque = opaque
    }

    /// 业务作用：在整行原始事件中只推进一次，同行多目标分别读取自己的前置动作和实际后继。
    /// 参数说明:
    /// - targets: 当前实际物理行的全部原替换目标。
    /// - structure: 从固定正文前面各行承接的结构。
    /// - output: 全部光标共用的尚未取得写入资格的动作。
    /// - check: 当前输入共同使用的继续资格。
    /// 返回：逐目标动作与完整行后的状态；超量或取消时不允许发布任何目标。
    func actions(
        for targets: [ByteRange],
        structure: inout PascalIndentationState,
        output: inout [ByteRange: NewlineIndentationAction],
        check: () throws -> Void
    ) throws {
        var index = 0
        var opaqueIndex = 0
        var opening: String?
        var closed: String?
        var closedStatement = false
        for target in targets.sorted(by: { $0.lower < $1.lower }) {
            try check()
            let offset = min(byteCount, target.lower - base)
            while index < spans.count, spans[index].range.upperBound <= offset {
                try check()
                opening = try update(
                    index,
                    structure: &structure,
                    closed: &closed,
                    terminated: &closedStatement
                )
                index += 1
            }
            while opaqueIndex < opaque.count, opaque[opaqueIndex].upperBound < offset {
                try check()
                opaqueIndex += 1
            }
            let next = index < spans.count ? spans[index] : nil
            let blocked =
                opaqueIndex < opaque.count && opaque[opaqueIndex].lowerBound < offset
                && (offset < opaque[opaqueIndex].upperBound
                    || endsOpaque && offset == byteCount && opaque[opaqueIndex].upperBound == offset)
            if blocked || next.map({ $0.range.lowerBound < offset }) == true {
                output[target] = .inherit
            }
            else if let opening {
                if let next, next.hasOnlySpaceBefore, structure.alignment(before: next.event) != nil {
                    output[target] = opening == prefix ? .expandPair : .expandAlignedPair(prefix: opening)
                }
                else {
                    output[target] = opening == prefix ? .increase : .align(prefix: opening, levels: 1)
                }
            }
            else if index == 0, let next, next.range.lowerBound == prefix.utf8.count,
                let origin = structure.alignment(before: next.event)
            {
                output[target] = .align(prefix: origin, levels: 0)
            }
            else if let closed {
                output[target] = .align(prefix: closed, levels: 0)
            }
            else {
                output[target] = .inherit
            }
        }
        while index < spans.count {
            try check()
            _ = try structure.consume(spans[index].event, prefix: prefix)
            index += 1
        }
    }

    /// 业务作用：仅独立的闭合语句可以决定后续缩进，同行其余代码不得沿用已结束作用域。
    /// 参数说明:
    /// - index: 当前已完整消费的真实事件序号。
    /// - structure: 光标此刻能使用的已确认块。
    /// - closed: 行首闭合语句的原始对齐前缀。
    /// - terminated: 独立闭合已经遇到实际语句终止符。
    /// 返回：本事件之后应新增一级时返回真实开端；其它事件只推进该行及跨行状态。
    private func update(
        _ index: Int,
        structure: inout PascalIndentationState,
        closed: inout String?,
        terminated: inout Bool
    ) throws -> String? {
        let span = spans[index]
        if index == 0, span.range.lowerBound == prefix.utf8.count,
            span.event == .keyword(.end) || span.event == .keyword(.until)
        {
            closed = structure.alignment(before: span.event)
        }
        else if closed != nil {
            if span.event == .terminator || span.event == .period && spans[0].event == .keyword(.end) {
                terminated = true
            }
            else if terminated || spans[0].event == .keyword(.end) {
                closed = nil
            }
        }
        return try structure.consume(span.event, prefix: prefix)
    }

    /// 业务作用：只把允许跨条件分支撤销的实际指令认作结构边界，普通编译设置不影响代码块。
    /// 参数说明:
    /// - start: 已经判定处于原生编译指令的当前原字节位置。
    /// - raw: 此行原始字节。
    /// - upper: 当前类别的真实末端。
    /// 返回：完整条件指令名的结束位置；普通指令、续行文字和更长名称返回空。
    private static func conditionStart(at start: Int, in raw: [UInt8], before upper: Int) -> Int? {
        let first: Int
        if raw[start] == 123, start + 1 < upper, raw[start + 1] == 36 {
            first = start + 2
        }
        else if raw[start] == 40, start + 2 < upper, raw[start + 1] == 42, raw[start + 2] == 36 {
            first = start + 3
        }
        else {
            return nil
        }
        var end = first
        while end < upper, end - first <= 6, PascalCharacters.word(raw[end]) {
            end += 1
        }
        let name = String(decoding: raw[first..<end].map(PascalCharacters.folded), as: UTF8.self)
        return ["if", "ifdef", "ifndef", "ifopt", "elseif", "else", "endif", "ifend"].contains(name)
            ? end : nil
    }

    /// 业务作用：确定可以原字节继承的 Pascal 行首缩进，只接受实际空格与 Tab。
    /// 参数说明:
    /// - byte: 完整物理行中的一个原字节。
    /// 返回：空格或 Tab 为真，其它字节保留正文语义。
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9
    }
}
