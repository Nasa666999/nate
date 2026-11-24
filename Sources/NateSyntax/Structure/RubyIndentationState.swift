import NateCore

struct RubyIndentationState {
    private typealias Word = RubyIndentationLexer.Word
    private typealias Token = RubyIndentationLexer.Token

    private struct Block {
        let word: Word
        let prefix: String
        let line: Int
        let byte: Int
    }

    private struct Header {
        let word: Word
        let blockIndex: Int
        let addsBlock: Bool
        var complete: Bool
        var active = true
        var parametersOpen = false
        var methodParts = 0
    }

    private var blocks: [Block] = []
    private var brackets: [UInt8] = []
    private var header: Header?
    private var closedPrefix: String?
    private var statementStart = true
    private var afterSeparator = false
    private var previous: Token?
    private var currentLine = 0
    private var base = 0
    private(set) var closedBlock: FoldRegion?

    /// 业务作用：新物理行清除上一行的完成动作，未闭合的真实表达式和声明继续使用同一结构来源。
    /// 参数说明:
    /// - line: 当前真实物理行号。
    /// - base: 当前行的绝对原字节起点。
    /// 返回：为当前行建立独立的动作边界；上一行仍有效的续接证据继续保留。
    mutating func beginLine(_ line: Int, base: Int) {
        currentLine = line
        self.base = base
        closedBlock = nil
        closedPrefix = nil
        afterSeparator = false
        previous = nil
        if header == nil && brackets.isEmpty {
            statementStart = true
        }
    }

    /// 业务作用：以原词序推进实际块、分支和结束端，普通后缀条件及名称不会冒充结构。
    /// 参数说明:
    /// - token: 当前完整且位于输入点之前的代码词元。
    /// - prefix: 此物理行已确认的原水平前缀。
    /// 返回：更新有界块状态；结构深度超限时不交付部分输入。
    mutating func consume(_ token: RubyIndentationLexer.Token, prefix: String) throws {
        closedBlock = nil
        if afterSeparator {
            // 分号有下一条实际语句时，前一条成功动作不再代替这个输入点的上下文。
            if case .symbol(59) = token.kind {
                return
            }
            header = nil
            closedPrefix = nil
            afterSeparator = false
        }
        let before = previous
        defer { previous = token }
        if case .symbol(let byte) = token.kind, try consumeBracket(byte) {
            if brackets.isEmpty, [41, 93, 125].contains(byte) {
                completeOperand()
            }
            statementStart = false
            return
        }
        // 括号内的词只完成所属参数，外层关键字不能由字面或另一条参数表达式代替。
        guard brackets.isEmpty else {
            return
        }
        if header?.word == .def, header?.active == true, header?.methodParts == 0,
            case .word = token.kind
        {
            header?.methodParts = 1
            completeOperand()
            return
        }
        switch token.kind {
        case .word(.end):
            closeCurrent(endingAt: token.span.upper)
        case .word(.then):
            header?.active = false
            statementStart = true
        case .word(.block):
            if let header, [.looping, .until, .iteration].contains(header.word), header.active {
                self.header?.active = false
                statementStart = true
            }
            else if before != nil && !statementStart {
                try open(.block, prefix: prefix, at: token.span.lower, complete: true)
            }
        case .word(let word) where statementStart:
            if [
                .conditional, .unless, .choice, .looping, .until, .iteration, .begin, .def, .module,
                .classBody,
            ]
            .contains(word) {
                try open(
                    word,
                    prefix: prefix,
                    at: token.span.lower,
                    complete: word == .begin || word == .choice
                )
            }
            else if let block = blocks.last, Self.accepts(word, in: block.word) {
                header = Header(
                    word: word,
                    blockIndex: blocks.count - 1,
                    addsBlock: false,
                    complete: ![.elsif, .when, .pattern].contains(word)
                )
                closedPrefix = nil
                statementStart = false
            }
            else {
                statementStart = false
            }
        case .assignment:
            if header?.word == .def, header?.active == true, header?.methodParts == 1,
                let before, before.span.upper < token.span.lower
            {
                // 在方法签名后确认了独立等号，单表达式方法没有可由 end 闭合的块。
                blocks.removeLast()
                header = nil
                closedPrefix = nil
            }
            else if header?.word != .def {
                header?.complete = false
            }
            // 没有实际左端的等号不会开启表达式，带缩进的 =begin 也不能建立异常处理块。
            statementStart = header == nil && before != nil
        case .symbol(59):
            finishIncompleteHeader()
            header?.active = false
            afterSeparator = true
            statementStart = true
        case .symbol(124) where header?.word == .block && header?.active == true:
            header?.parametersOpen.toggle()
            let confirmed = header?.parametersOpen == false
            header?.complete = confirmed
            if confirmed {
                header?.active = false
            }
        case .word(.and), .word(.or), .word(.not):
            if header?.active == true {
                header?.complete = false
            }
            statementStart = false
        case .symbol(let byte) where [33, 37, 38, 42, 43, 44, 45, 46, 47, 60, 61, 62, 94, 126].contains(byte):
            if header?.active == true && header?.word != .def {
                header?.complete = false
            }
            statementStart = false
        case .operand:
            if token.literal, let word = header?.word, [.def, .module, .classBody].contains(word),
                header?.active == true, header?.complete == false
            {
                return
            }
            if header?.active == true, header?.word == .def {
                if let before, case .symbol(let byte) = before.kind, byte == 46 || byte == 58 {
                    // 点号或命名空间之后的实际方法名仍属于同一签名。
                }
                else {
                    header?.methodParts += 1
                }
            }
            completeOperand()
        default:
            statementStart = false
        }
    }

    /// 业务作用：Ruby 换行只使用已经确认的当前结构，根据实际后继闭合位置对齐或展开内外两行。
    /// 参数说明:
    /// - next: 真实替换范围后保留下来的首个完整词元。
    /// 返回：本次输入可使用的原前缀动作，参数或边界仍缺失时只继承。
    func action(before next: RubyIndentationLexer.Token?) -> NewlineIndentationAction {
        guard brackets.isEmpty else {
            return .inherit
        }
        if let header, header.complete, blocks.indices.contains(header.blockIndex) {
            let prefix = blocks[header.blockIndex].prefix
            if let next, case .word(.end) = next.kind, header.blockIndex == blocks.count - 1 {
                return .expandAlignedPair(prefix: prefix)
            }
            return .align(prefix: prefix, levels: 1)
        }
        if let closedPrefix {
            return .align(prefix: closedPrefix, levels: 0)
        }
        if previous == nil, let block = blocks.last, let next, case .word(.end) = next.kind {
            return .align(prefix: block.prefix, levels: 0)
        }
        return .inherit
    }

    /// 业务作用：在真实行尾决定位于括号、显式续接或未结束表达式中的声明是否交由下一行。
    /// 参数说明:
    /// - opaque: 当前仍有待完成的原字面。
    /// 返回：完成的块保留，无法继续确认的未完成声明撤去其结构权限。
    mutating func finishLine(opaque: Bool) {
        if opaque || !brackets.isEmpty || Self.continues(previous) {
            return
        }
        finishIncompleteHeader()
        header = nil
    }

    /// 业务作用：建立只能由真实 Ruby 结束词终止的块，保留开端原前缀及待确认声明。
    /// 参数说明:
    /// - word: 已识别的块开端词或实际 do。
    /// - prefix: 块首物理行的原始水平空白。
    /// - offset: 当前物理行内真实开端词的原字节偏移。
    /// - complete: 该声明已经具备自身所需最小上下文时为真。
    /// 返回：进入新的有界结构；深度不足时拒绝整批。
    private mutating func open(_ word: Word, prefix: String, at offset: Int, complete: Bool) throws {
        guard blocks.count < 4096 else {
            throw NateError.message("Ruby 结构缩进超过 4096 层活动块。")
        }
        blocks.append(Block(word: word, prefix: prefix, line: currentLine, byte: base + offset))
        header = Header(word: word, blockIndex: blocks.count - 1, addsBlock: true, complete: complete)
        closedPrefix = nil
        statementStart = word == .begin
    }

    /// 业务作用：关闭前先收束当前尚未完成的局部声明，只有已确认的开端才给出正文前缀。
    /// 参数说明:
    /// - offset: 当前实际结束词的相对排他末端。
    /// 返回：原开端仍完整时保存对齐前缀，真实跨行时同时交付折叠范围。
    private mutating func closeCurrent(endingAt offset: Int) {
        if let header, !header.complete {
            // 不完整的内层语句可能改变结束词的归属，停止继承此前的所有块资格。
            blocks.removeAll()
            closedPrefix = nil
        }
        else {
            let block = blocks.popLast()
            closedPrefix = block?.prefix
            if let block, block.line < currentLine {
                closedBlock = FoldRegion(
                    range: ByteRange(block.byte, base + offset),
                    startLine: block.line,
                    endLine: currentLine,
                    level: 0
                )
            }
        }
        header = nil
        statementStart = false
    }

    /// 业务作用：完整操作数结束待确认的条件或参数，未闭合的块参数仍保护当前光标。
    /// 参数说明: 无。
    /// 返回：可用的 Ruby 表达式进入可缩进状态。
    private mutating func completeOperand() {
        if header?.active == true && header?.parametersOpen == false {
            header?.complete = true
        }
        statementStart = false
    }

    /// 业务作用：实际语句边界缺少声明所需证据时撤去该开端，外层闭合不能借伪块对齐。
    /// 参数说明: 无。
    /// 返回：未真正开启的块移除，原外层或普通分支仍保留。
    private mutating func finishIncompleteHeader() {
        guard let header, !header.complete, header.addsBlock, blocks.count - 1 == header.blockIndex else {
            return
        }
        blocks.removeLast()
    }

    /// 业务作用：括号、方括号及花括号阻隔本行的外层语句，不让内层标点影响外层结构。
    /// 参数说明:
    /// - byte: 当前实际操作符原字节。
    /// 返回：已处理括号类边界时为真；配对不明时撤销不可靠的结构资格。
    private mutating func consumeBracket(_ byte: UInt8) throws -> Bool {
        if let closer: UInt8 = [40: 41, 91: 93, 123: 125][byte] {
            guard brackets.count < 4096 else {
                throw NateError.message("Ruby 括号结构超过 4096 层。")
            }
            brackets.append(closer)
            return true
        }
        guard [41, 93, 125].contains(byte) else {
            return false
        }
        if brackets.popLast() != byte {
            // 错配的括号使后续关键字所属的语句不确定，停止沿用旧块。
            brackets.removeAll()
            blocks.removeAll()
            header = nil
            closedPrefix = nil
        }
        return true
    }

    /// 业务作用：公开分支只继承所属 Ruby 结构的真实原开端。
    /// 参数说明:
    /// - branch: 当前有效的分支词。
    /// - word: 最内层实际开放的块类别。
    /// 返回：该分支属于此类别时为真。
    private static func accepts(_ branch: Word, in word: Word) -> Bool {
        switch word {
        case .conditional:
            branch == .elsif || branch == .fallback
        case .unless:
            branch == .fallback
        case .choice:
            [.when, .pattern, .fallback].contains(branch)
        case .begin, .def, .classBody, .module, .block:
            [.rescue, .fallback, .ensure].contains(branch)
        default:
            false
        }
    }

    /// 业务作用：复用实际末尾操作符判断同一声明是否跨物理行继续。
    /// 参数说明:
    /// - token: 本物理行最后一个真实代码词元。
    /// 返回：需要读取下一物理行的操作符或表达式连接词时为真。
    private static func continues(_ token: Token?) -> Bool {
        guard let token else {
            return false
        }
        switch token.kind {
        case .assignment, .word(.and), .word(.or):
            return true
        case .symbol(let byte):
            return [37, 38, 42, 43, 44, 45, 46, 47, 60, 61, 62, 92, 94].contains(byte)
        default:
            return false
        }
    }
}
