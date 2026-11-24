import NateCore

struct YAMLIndentationState {
    struct Flow {
        let close: UInt8
        let column: Int
    }

    struct BlockScalar {
        let parent: Int
        var minimum: Int?
    }

    enum PlainScalar {
        case flow
        case block(parent: Int)
    }

    var flow: [Flow] = []
    var scalar: BlockScalar?
    var quote: UInt8?
    var plain: PlainScalar?

    /// 业务作用：延续块标量的正文范围，使其中的标点和注释外观保持字面身份。
    /// 参数说明:
    /// - indentation: 下一物理行的前导 ASCII 空格列数。
    /// - blank: 本行没有正文。
    /// 返回：仍属于块标量时成立；实际退格会结束标量，推断高度由首个非空正文确定。
    mutating func protectsScalar(indentation: Int, blank: Bool) -> Bool {
        guard let current = scalar else {
            return false
        }
        if blank {
            return true
        }
        // 首个非空行一旦确定正文高度，后续处于父行与该高度之间的行也不能继续冒充字面内容。
        guard indentation > current.parent, indentation >= (current.minimum ?? 0) else {
            scalar = nil
            return false
        }
        if current.minimum == nil {
            scalar?.minimum = indentation
        }
        return true
    }
}

struct YAMLIndentationLine {
    enum Action {
        case inherit
        case increase
        case expandPair
        case align(column: Int, levels: Int)
    }

    private enum Tail {
        case start
        case value
        case quotedValue
        case pendingNode(Int)
        case open(UInt8)
        case leadingClose(Int)
        case scalar(Int, Int?)
    }

    private let bytes: [UInt8]
    private let indentation: Int
    private let opaque: Bool
    private var cursor = 0
    private var tail: Tail = .start
    private var nodeStart = true
    private var compactChild = false
    private var keyColumn: Int?
    private var blockColumn: Int

    /// 业务作用：确定当前物理行的语法起点、原始空格和沿用的字面范围。
    /// 参数说明:
    /// - bytes: 不包含换行字节的物理行。
    /// - state: 由同一文档前置行传播的词法证据。
    /// - check: 当前输入准备的继续资格。
    /// 返回：可顺序读取的本行扫描器；已确定的块标量正文和非法 Tab 缩进保持原行行为。
    init(bytes: [UInt8], state: inout YAMLIndentationState, check: () throws -> Void) throws {
        self.bytes = bytes
        var indentation = 0
        while indentation < bytes.count, bytes[indentation] == 32 {
            if indentation & 255 == 0 {
                try check()
            }
            indentation += 1
        }
        self.indentation = indentation
        blockColumn = indentation
        opaque =
            state.protectsScalar(indentation: indentation, blank: indentation == bytes.count)
            || state.quote == nil && indentation < bytes.count && bytes[indentation] == 9
        if !opaque, indentation == 0, state.quote == nil {
            if bytes.first == 37 {
                state.plain = nil
                cursor = bytes.count
            }
            else if bytes.count >= 3, bytes[0] == bytes[1], bytes[1] == bytes[2],
                (bytes[0] == 45 || bytes[0] == 46), bytes.count == 3 || Self.isSeparation(bytes[3])
            {
                // 真实文档边界丢弃前一份文档未闭合的流容器，避免新文档借用旧缩进。
                state.flow.removeAll(keepingCapacity: true)
                state.plain = nil
                cursor = bytes[0] == 45 ? 3 : bytes.count
            }
        }
        // 无引号标量可以折叠跨行空白，续行首个引号仍为普通内容。块标量的同级或外层正文结束这种延续。
        if case .block(let parent) = state.plain, indentation < bytes.count, indentation <= parent {
            state.plain = nil
        }
        nodeStart = state.plain == nil
    }

    /// 业务作用：读取插入点之前的 YAML 语法，保留跨行引号、流容器及块正文的真实范围。
    /// 参数说明:
    /// - offset: 当前行中本次需要读到的原字节偏移。
    /// - state: 可在本行以及后续物理行继续使用的上下文。
    /// - check: 当前事务的继续资格。
    /// 返回：成功时推进至指定位置或覆盖该处的完整字面词；超量或取消会放弃本批动作。
    mutating func scan(
        through offset: Int,
        state: inout YAMLIndentationState,
        check: () throws -> Void
    ) throws {
        guard !opaque else {
            return
        }
        var nextCheck = cursor
        while cursor < offset {
            if cursor >= nextCheck {
                try check()
                nextCheck = cursor + 256
            }
            let byte = bytes[cursor]
            let next = cursor + 1 < bytes.count ? bytes[cursor + 1] : nil
            if let quote = state.quote {
                readQuoted(byte, next: next, quote: quote, state: &state)
                continue
            }
            if Self.isSeparation(byte) {
                cursor += 1
                continue
            }
            if byte == 35, cursor == 0 || Self.isSeparation(bytes[cursor - 1]) {
                state.plain = nil
                cursor = bytes.count
                continue
            }
            if compactChild {
                keyColumn = cursor
                compactChild = false
            }
            let inFlow = !state.flow.isEmpty
            if nodeStart, byte == 34 || byte == 39 {
                state.plain = nil
                state.quote = byte
                nodeStart = false
                tail = .value
            }
            else if (nodeStart || inFlow), byte == 91 || byte == 123 {
                // 限制真实流容器的深度，超量时不给任何目标发布缺失外层信息的对齐。
                guard state.flow.count < 4096 else {
                    throw NateError.message("YAML 流容器嵌套超过 4096 层。")
                }
                let close: UInt8 = byte == 91 ? 93 : 125
                state.flow.append(.init(close: close, column: indentation))
                state.plain = nil
                tail = .open(close)
                nodeStart = true
                keyColumn = nil
            }
            else if inFlow, byte == 93 || byte == 125 {
                state.plain = nil
                closeFlow(byte, state: &state)
            }
            else if inFlow, byte == 44 {
                state.plain = nil
                tail = .value
                nodeStart = true
                keyColumn = nil
            }
            else if byte == 58, isMappingSeparator(next, inFlow: inFlow) {
                state.plain = nil
                blockColumn = keyColumn ?? blockColumn
                tail = .pendingNode(blockColumn)
                nodeStart = true
                keyColumn = nil
            }
            else if nodeStart, !inFlow, (byte == 45 || byte == 63), next.map(Self.isSeparation) ?? true {
                blockColumn = keyColumn ?? blockColumn
                tail = .pendingNode(blockColumn)
                compactChild = true
            }
            else if nodeStart, !inFlow, (byte == 124 || byte == 62),
                let header = try scalarHeader(check: check)
            {
                let minimum = header.indent.map { blockColumn + $0 }
                state.scalar = .init(parent: blockColumn, minimum: minimum)
                tail = .scalar(blockColumn, minimum)
                nodeStart = false
                cursor = header.end
                continue
            }
            else if nodeStart, byte == 33 || byte == 38 || byte == 42 {
                cursor = try nodeProperty(inFlow: inFlow, check: check)
                nodeStart = byte != 42
                tail = .value
                continue
            }
            else {
                if state.plain == nil {
                    state.plain = inFlow ? .flow : .block(parent: blockColumn)
                }
                tail = .value
                nodeStart = false
            }
            cursor += 1
        }
    }

    /// 业务作用：依据选区两侧仍真实存在的语法，确认继承、增级、成对展开或明确对齐。
    /// 参数说明:
    /// - offset: 折行的真实行内位置。
    /// - following: 选区之后同一行的首个非空白原字节。
    /// - state: 截至插入点传播的当前语法证据。
    /// 返回：一个完整结构动作；字面内部、无可确认开端或闭合时继承。
    func action(at offset: Int, following: UInt8?, state: YAMLIndentationState) -> Action {
        guard !opaque, state.quote == nil, cursor <= offset else {
            return .inherit
        }
        switch tail {
        case .start:
            if let flow = state.flow.last, following == flow.close {
                return .align(column: flow.column, levels: 0)
            }
            return .inherit
        case .pendingNode(let column):
            return column == indentation ? .increase : .align(column: column, levels: 1)
        case .open(let close):
            return following == close ? .expandPair : .increase
        case .leadingClose(let column):
            return .align(column: column, levels: 0)
        case .scalar(let column, let minimum):
            if let minimum {
                return .align(column: minimum, levels: 0)
            }
            return column == indentation ? .increase : .align(column: column, levels: 1)
        case .value, .quotedValue:
            return .inherit
        }
    }

    /// 业务作用：越过引号字面及其转义，避免字面标点影响容器和块缩进。
    /// 参数说明:
    /// - byte: 当前字节。
    /// - next: 同一物理行的下一字节。
    /// - quote: 当前正在读取的单引号或双引号。
    /// - state: 保存开闭引用位置之外的行间状态。
    /// 返回：推进一个字面单位；只有未转义结束符解除引用。
    private mutating func readQuoted(
        _ byte: UInt8,
        next: UInt8?,
        quote: UInt8,
        state: inout YAMLIndentationState
    ) {
        if quote == 34, byte == 92 {
            cursor += next == nil ? 1 : 2
        }
        else if quote == 39, byte == quote, next == quote {
            cursor += 2
        }
        else {
            if byte == quote {
                state.quote = nil
                tail = .quotedValue
                nodeStart = false
            }
            cursor += 1
        }
    }

    /// 业务作用：只用配对的流容器为行首闭合对齐，连续闭合采用最后一个可靠来源。
    /// 参数说明:
    /// - byte: 原行的右方括号或右花括号。
    /// - state: 当前未闭合流容器的完整栈。
    /// 返回：已匹配时收束一层；类型不符时保持前置证据，不制造对齐。
    private mutating func closeFlow(_ byte: UInt8, state: inout YAMLIndentationState) {
        guard let matching = state.flow.last, matching.close == byte else {
            tail = .value
            nodeStart = false
            return
        }
        state.flow.removeLast()
        switch tail {
        case .start, .leadingClose:
            tail = .leadingClose(matching.column)
        default:
            tail = .value
        }
        nodeStart = false
        keyColumn = nil
    }

    /// 业务作用：区分真正的键值分隔与 URL、普通标量或数值内部的冒号。
    /// 参数说明:
    /// - next: 冒号后的第一个原字节。
    /// - inFlow: 冒号位于已读取的流容器内。
    /// 返回：存在允许的分隔证据时成立，流式双引号或单引号键可紧邻其值。
    private func isMappingSeparator(_ next: UInt8?, inFlow: Bool) -> Bool {
        guard let next else {
            return true
        }
        if Self.isSeparation(next) || inFlow && Self.isFlowIndicator(next) {
            return true
        }
        if case .quotedValue = tail {
            return inFlow
        }
        return false
    }

    /// 业务作用：确认块标量头的截断、保留及显式空格高度，不借用普通标量中的竖线或尖括号。
    /// 参数说明:
    /// - check: 当前事务的继续资格。
    /// 返回：有效标量头的末端及可选高度；头部包含其它内容时为空。
    private func scalarHeader(check: () throws -> Void) throws -> (end: Int, indent: Int?)? {
        var end = cursor + 1
        var indent: Int?
        var chomping = false
        for _ in 0..<2 where end < bytes.count {
            let byte = bytes[end]
            if indent == nil, (49...57).contains(byte) {
                indent = Int(byte - 48)
            }
            else if !chomping, byte == 43 || byte == 45 {
                chomping = true
            }
            else {
                break
            }
            end += 1
        }
        if end < bytes.count {
            guard Self.isSeparation(bytes[end]) else {
                return nil
            }
            var suffix = end
            while suffix < bytes.count, Self.isSeparation(bytes[suffix]) {
                if suffix & 255 == 0 {
                    try check()
                }
                suffix += 1
            }
            guard suffix == bytes.count || bytes[suffix] == 35 else {
                return nil
            }
        }
        return (end, indent)
    }

    /// 业务作用：消费完整的标记、锚点或别名，保护 URI、中间冒号与分隔符免于误判。
    /// 参数说明:
    /// - inFlow: 节点属性是否受流容器的标点边界约束。
    /// - check: 当前事务的继续资格。
    /// 返回：属性的原字节末端，未完成的长标记保留到本行末端。
    private func nodeProperty(inFlow: Bool, check: () throws -> Void) throws -> Int {
        var end = cursor + 1
        let verbatim = bytes[cursor] == 33 && end < bytes.count && bytes[end] == 60
        while end < bytes.count {
            if end & 255 == 0 {
                try check()
            }
            let byte = bytes[end]
            if Self.isSeparation(byte) || !verbatim && inFlow && Self.isFlowIndicator(byte) {
                break
            }
            end += 1
            if verbatim, byte == 62 {
                break
            }
        }
        return end
    }

    /// 业务作用：识别允许分隔 YAML 词元的行内 ASCII 空白。
    /// 参数说明:
    /// - byte: 不含物理换行的原字节。
    /// 返回：空格或 Tab 时成立。
    static func isSeparation(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9
    }

    /// 业务作用：识别流容器能够分隔内部标量的五种结构标点。
    /// 参数说明:
    /// - byte: 待确认的 ASCII 原字节。
    /// 返回：逗号、方括号或花括号时成立。
    private static func isFlowIndicator(_ byte: UInt8) -> Bool {
        byte == 44 || byte == 91 || byte == 93 || byte == 123 || byte == 125
    }
}
