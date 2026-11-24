import Foundation
import NateCore

enum FortranIndentationPlan {
    private typealias Block = FortranIndentationLine.Block

    private struct Frame {
        let block: Block
        let name: String?
        let prefix: ByteRange

        /// 业务作用：闭合必须属于当前真实结构，同名变量、不同名字的块或单独 END 不能结束任意一层。
        /// 参数说明:
        /// - requested: 闭合或分支实际声明的块类别；裸 END 省略类别。
        /// - name: 已确认的可选结构名。
        /// - closing: 是否需要验证闭合端的命名约束。
        /// 返回：类别和要求的原声明名称均匹配时为真。
        func matches(_ requested: Block?, name: String?, closing: Bool = true) -> Bool {
            guard requested == block || requested == nil && block.usesBareEnd else {
                return false
            }
            if let name {
                return self.name == name
            }
            return !closing || self.name == nil || block.usesBareEnd || block == .interface
        }
    }

    private struct Continuation {
        let prefix: ByteRange
        var atoms: [FortranIndentationLine.Atom] = []
        var sourceBytes = 0
        var trailing: FortranIndentationLine.Atom?
        var unresolved = false

        /// 业务作用：合并已由原生词法确认的物理续行，保留同一原语句的开放或关闭资格。
        /// 参数说明:
        /// - content: 当前物理行属于同一条逻辑语句的原词元。
        /// - bytes: 当前片段的原字节数，含所属物理结束符或语句分隔符。
        /// - leading: 当前片段之前真实存在的自由格式续行标记。
        /// - pending: 当前片段之后真实存在的自由格式续行标记。
        /// 返回：安全的完整原词元顺序；跨行拆开的名称标为未确认，超限拒绝整批。
        mutating func append(
            _ content: ArraySlice<FortranIndentationLine.Atom>,
            bytes: Int,
            leading: FortranIndentationLine.Atom?,
            pending: FortranIndentationLine.Atom?
        ) throws {
            guard bytes <= 1_048_576 - sourceBytes, content.count <= 65_536 - atoms.count else {
                throw NateError.message("Fortran 续接语句超过 1 MiB 或 65536 个词元。")
            }
            sourceBytes += bytes
            if let leading, let pending, leading.range == pending.range {
                unresolved = true
            }
            // 无间隔写在两个物理续行符旁的名称可能是同一个词，部分结果不能冒充语义关键字。
            if let trailing, let previous = atoms.last, let first = content.first, let leading,
                previous.range.upper == trailing.range.lower, first.range.lower == leading.range.upper,
                Self.wordPart(previous), Self.wordPart(first)
            {
                unresolved = true
            }
            if !content.isEmpty || pending != nil {
                trailing = pending
            }
            atoms.append(contentsOf: content)
        }

        /// 业务作用：名称及数字续接可能拼成不同原词，无法确认的半段不具备结构资格。
        /// 参数说明:
        /// - atom: 原生词法确认的当前边缘词元。
        /// 返回：可归入被拆开名称或数字时为真。
        private static func wordPart(_ atom: FortranIndentationLine.Atom) -> Bool {
            atom.identifier || atom.value.utf8.first.map { (48...57).contains($0) } == true
        }
    }

    /// 业务作用：Fortran 换行使用实际源格式和原生词法已确认的完整结构，所有光标共享同一正文和准备期限。
    /// 参数说明:
    /// - snapshot: 所有真实输入目标固定的不可变正文。
    /// - language: 实际自由格式或固定格式词表及样式资源。
    /// - ranges: 已验证的普通或矩形真实替换范围。
    /// - deadline: 前置词法、原前缀、事务及提交的实际共同截止。
    /// - permit: 本次编辑继续有效的资格。
    /// 返回：完整逐目标缩进动作；固定格式保护列、未确认续行及特殊声明不借用冲突结构。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：原生传播和全部光标只使用本次输入的继续资格。
        /// 参数说明: 无。
        /// 返回：操作仍有效时继续；过期或取消停止整份计划。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Fortran 结构缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            byLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Fortran 结构缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        let fixedFormat = language.id == "fortran77"
        var lexical = SyntaxState()
        var sourcesRemaining = 64 * 1_048_576
        var prefixesRemaining = 1_048_576
        var prefixCache: [ByteRange: String] = [:]
        var scopes: [Frame] = []
        var continuation: Continuation?
        var result: [ByteRange: NewlineIndentationAction] = [:]

        /// 业务作用：真实开端的混合空白只读取一次，所有编辑目标共同使用容量。
        /// 参数说明:
        /// - range: 已确认的原始水平空白范围。
        /// 返回：完整原空白；超过一次输入的共同容量整批拒绝。
        func prefix(_ range: ByteRange) throws -> String {
            if let cached = prefixCache[range] {
                return cached
            }
            guard range.count <= prefixesRemaining else {
                throw NateError.message("Fortran 结构缩进需要的完整原前缀超过 1 MiB。")
            }
            prefixesRemaining -= range.count
            let value = text.text(in: range)
            prefixCache[range] = value
            return value
        }

        /// 业务作用：当前语句自身与同一已确认外层决定下一行的原始前缀，关闭发生前保留开端证据。
        /// 参数说明:
        /// - event: 按真实原词元完成的本语句角色。
        /// - origin: 本语句首个物理行的原空白。
        /// - scope: 处理本语句前实际可用的最内层结构。
        /// 返回：能确切求得的语言动作；语句和当前块不吻合时为空。
        func indentation(
            after event: FortranIndentationLine.Event,
            origin: ByteRange,
            scope: Frame?
        ) throws -> NewlineIndentationAction? {
            switch event {
            case .opening:
                return .align(prefix: try prefix(origin), levels: 1)
            case .branch(let block, let name, let levels):
                guard let scope, scope.matches(block, name: name, closing: false) else {
                    return nil
                }
                return .align(prefix: try prefix(scope.prefix), levels: levels)
            case .closing(let block, let name):
                guard let scope, scope.matches(block, name: name) else {
                    return nil
                }
                return .align(prefix: try prefix(scope.prefix), levels: 0)
            case .neutral:
                return nil
            }
        }

        for line in 0...last {
            try check()
            let physical = text.lineRange(line)
            let content = text.lineRange(line, includeEnding: false)
            // 整个前置范围必须先具备读取资格，任何目标失败都不能留下先前光标的部分缩进。
            guard physical.count <= 1_048_576, physical.count <= sourcesRemaining else {
                throw NateError.message("Fortran 结构缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            sourcesRemaining -= physical.count
            let source = text.text(in: physical)
            let tokens = scanner.highlight(source, base: physical.lower, state: &lexical)
            if let error = lexical.diagnostic {
                throw NateError.message(error)
            }
            let bytes = Array(source.utf8.prefix(content.count))
            let row = try FortranIndentationLine(
                bytes: bytes,
                range: content,
                tokens: tokens,
                languageID: language.id,
                check: check
            )
            let targets = byLine[line] ?? []
            if fixedFormat, !row.atoms.isEmpty {
                // 前五列只能承担标签，第六列可能续接上一语句。仅六个连续的原空格取得普通结构缩进资格。
                let ordinaryColumns = bytes.count >= 6 && bytes.prefix(6).allSatisfy { $0 == 32 }
                let followingContinuation =
                    ordinaryColumns
                    ? try fixedContinuationFollows(after: line, text: text, check: check) : false
                if !ordinaryColumns || followingContinuation {
                    scopes.removeAll()
                    for target in targets {
                        try check()
                        result[target] = .inherit
                    }
                    continue
                }
            }
            if (fixedFormat && row.crossesStatements) || row.directive
                || (row.beginsContinuation && continuation == nil)
            {
                // 预处理或来源不确定的续接可能改变原语句关系，不能沿用旧块作为缩进来源。
                scopes.removeAll()
                continuation = nil
                for target in targets {
                    try check()
                    result[target] = .inherit
                }
                continue
            }
            let ordered = targets.sorted { $0.lower < $1.lower }
            var targetIndex = 0
            var start = row.beginsContinuation ? 1 : 0
            let end = max(start, row.atoms.count - (row.endsContinuation ? 1 : 0))
            var startByte = physical.lower
            var boundaries: [Int] = []
            if row.crossesStatements {
                for index in start..<end {
                    try check()
                    if row.atoms[index].value == ";" {
                        boundaries.append(index)
                    }
                }
            }
            boundaries.append(end)
            var prior: (event: FortranIndentationLine.Event, origin: ByteRange, scope: Frame?)?
            for boundary in boundaries {
                try check()
                let separator = boundary < end ? row.atoms[boundary] : nil
                let limit = separator?.range.lower ?? content.upper
                let nextByte = separator?.range.upper ?? physical.upper
                let incoming = continuation != nil
                let earlier = continuation?.atoms.count ?? 0
                let statementOrigin = continuation?.prefix ?? row.prefix
                let local = row.atoms[start..<boundary]
                let leading = startByte == physical.lower && row.beginsContinuation ? row.atoms.first : nil
                let pending = separator == nil && row.endsContinuation ? row.atoms.last : nil
                let waitsForMore = pending != nil || incoming && row.atoms.isEmpty
                if incoming || pending != nil {
                    if continuation == nil {
                        continuation = Continuation(prefix: statementOrigin)
                    }
                    try continuation?.append(
                        local,
                        bytes: nextByte - startByte,
                        leading: leading,
                        pending: pending
                    )
                }
                // 只有分隔符之前的完整语句可以改变后继结构；拆开的词使本语句的原前缀证据失效。
                let uncertain = continuation?.unresolved == true
                if uncertain {
                    scopes.removeAll()
                }
                let complete =
                    continuation.map {
                        $0.atoms[...]
                    } ?? local
                while targetIndex < ordered.count,
                    min(ordered[targetIndex].lower, content.upper) <= limit
                {
                    try check()
                    let target = ordered[targetIndex]
                    targetIndex += 1
                    let position = min(target.lower, content.upper)
                    guard !waitsForMore, !uncertain, leading.map({ $0.range.upper <= position }) != false,
                        let before = row.prefixAtoms(at: position)
                    else {
                        result[target] = .inherit
                        continue
                    }
                    let count = earlier + max(0, min(before.count, boundary) - start)
                    let statement = complete.prefix(count)
                    let event = try FortranIndentationLine.classify(statement, check: check)
                    if let found = try indentation(after: event, origin: statementOrigin, scope: scopes.last)
                    {
                        result[target] = found
                        continue
                    }
                    if case .neutral = event, earlier == 0, statement.isEmpty,
                        target.upper < limit, let tail = row.suffixAtoms(at: target.upper, endingAt: limit)
                    {
                        let actual = try FortranIndentationLine.classify(tail, check: check)
                        if case .closing = actual,
                            let indent = try indentation(
                                after: actual,
                                origin: statementOrigin,
                                scope: scopes.last
                            )
                        {
                            result[target] = indent
                            continue
                        }
                    }
                    if complete.isEmpty, let prior {
                        result[target] =
                            try indentation(after: prior.event, origin: prior.origin, scope: prior.scope)
                            ?? .inherit
                    }
                    else {
                        result[target] = .inherit
                    }
                }
                if waitsForMore {
                    // 注释和空白保留待续语句；最后一段未结束时，前面的独立语句已按真实顺序处理。
                    break
                }
                continuation = nil
                start = boundary + 1
                startByte = nextByte
                if uncertain {
                    prior = nil
                    continue
                }
                let event = try FortranIndentationLine.classify(complete, check: check)
                if separator != nil, !complete.isEmpty {
                    prior = (event, statementOrigin, scopes.last)
                }
                // 本语句全部目标先取得先前的块证据，再把当前完整语句的开闭关系推进给后继语句。
                switch event {
                case .opening(let block, let name):
                    guard scopes.count < 4096 else {
                        throw NateError.message("Fortran 结构缩进超过 4096 层活动块。")
                    }
                    scopes.append(Frame(block: block, name: name, prefix: statementOrigin))
                case .closing(let block, let name):
                    if let scope = scopes.last, scope.matches(block, name: name) {
                        scopes.removeLast()
                    }
                    else {
                        // 未匹配的关闭可能已经结束外层的语义范围，后续输入不能再沿这个不确定的栈对齐。
                        scopes.removeAll()
                    }
                case .branch, .neutral:
                    break
                }
            }
        }
        try check()
        return result
    }

    /// 业务作用：固定格式必须看清下一条有效记录的真实第六列，不能把后续续接的上一行当成完整声明。
    /// 参数说明:
    /// - line: 正在确认的实际物理行号。
    /// - text: 本次输入固定的完整正文。
    /// - check: 全部目标共同拥有的继续资格。
    /// 返回：下一条有效记录的第六列是有效续接标记时为真，文件尾或新语句时为假。
    private static func fixedContinuationFollows(
        after line: Int,
        text: PieceTree,
        check: () throws -> Void
    ) throws -> Bool {
        var visited = 0
        for next in (line + 1)..<text.lineCount {
            try check()
            let row = text.lineRange(next, includeEnding: false)
            let length = min(72, row.count)
            guard visited <= 64 * 1_048_576 - length, next < 1_048_576 else {
                throw NateError.message("Fortran 固定格式续接前瞻超过原文或行数预算。")
            }
            visited += length
            let bytes = text.bytes(in: ByteRange(row.lower, row.lower + length))
            if bytes.first.map({ [67, 99, 42].contains($0) }) == true {
                continue
            }
            guard let first = bytes.firstIndex(where: { !FortranCharacters.space(UInt32($0)) }),
                bytes[first] != 33
            else {
                continue
            }
            // 以原字节计算列，不把用户配置的可见 Tab 停靠位当作固定格式的字段位置。
            return bytes.count >= 6 && !FortranCharacters.space(UInt32(bytes[5])) && bytes[5] != 48
                && bytes[5] != 33
        }
        return false
    }

}
