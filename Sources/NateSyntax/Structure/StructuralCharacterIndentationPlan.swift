import Foundation
import NateCore

public struct StructuralCharacterIndentationPlan: Sendable {
    private let snapshot: DocumentSnapshot
    private let entries: [UUID: SelectionEntry]
    private let prefixes: [UUID: String]
    private let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool

    /// 业务作用：独立结构字符沿同一词法传播确认前导空白，闭合符只对齐真实代码中的同类开端。
    /// 参数说明:
    /// - snapshot: 带完整普通选择及控制代次的固定正文。
    /// - input: 本次实际输入的单个花括号或 JSON 方括号。
    /// - language: 当前内置语言，没有适用规则时保留原前缀。
    /// - udl: 当前用户语言，尚无规则时保留原前缀。
    /// - settings: 当前语言的 Tab 宽度及新增空白方式。
    /// - deadline: 全部词法、前缀和最终事务共用的截止。
    /// - permit: 本次完整输入仍有准备资格。
    /// 返回：不修改来源的逐目标前缀；词法、边界、容量或执行资格不足时整体失败。
    public init(
        snapshot: DocumentSnapshot,
        input: String,
        language: LanguageDefinition?,
        udl: UDLDefinition?,
        settings: TabSettings,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Self.check(deadline: deadline, permit: permit)
        guard let state = snapshot.selectionState, case .stream = state.shape,
            snapshot.selectionGeneration != nil
        else {
            throw NateError.message("结构字符对齐需要完整普通选择身份。")
        }
        let normalized = try state.normalized(
            in: snapshot.text,
            permit: {
                permit() && ContinuousClock.now < deadline
            }
        )
        self.snapshot = snapshot
        entries = Dictionary(
            uniqueKeysWithValues: normalized.entries.map {
                ($0.id, $0)
            }
        )
        self.deadline = deadline
        self.permit = permit
        let identifier = language?.id ?? "normal"
        let curly: Set<String> = [
            "c", "cpp", "java", "cs", "objc", "php", "javascript", "javascript.js", "jsp", "css",
            "perl", "rust", "powershell", "json", "json5", "typescript", "go", "swift",
        ]
        let array = identifier == "json" || identifier == "json5"
        guard udl == nil, let language, curly.contains(identifier),
            input == "{" || input == "}" || array && (input == "[" || input == "]")
        else {
            prefixes = [:]
            return
        }
        var byLine: [Int: [SelectionEntry]] = [:]
        for entry in normalized.entries {
            byLine[snapshot.text.lineNumber(at: entry.selection.range.lower), default: []].append(entry)
        }
        let lastLine = byLine.keys.max() ?? 0
        guard lastLine < 1_048_576 else {
            throw NateError.message("结构字符的前置词法传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var stack: [(byte: UInt8, line: Int)] = []
        var previous: (line: Int, increase: Bool)?
        var output: [UUID: String] = [:]
        var consumed = 0, prefixBytes = 0
        for line in 0...lastLine {
            try Self.check(deadline: deadline, permit: permit)
            let range = snapshot.text.lineRange(line)
            guard range.count <= 1_048_576, range.count <= 67_108_864 - consumed else {
                throw NateError.message("结构字符对齐超过单行 1 MiB 或前置原文 64 MiB。")
            }
            consumed += range.count
            let source = Array(snapshot.text.bytes(in: range))
            let initial = lexical
            let startsOpaque =
                !lexical.blockEnd.isEmpty || lexical.c.blockComment || lexical.c.lineComment
                || lexical.c.quote != nil || lexical.c.regex || lexical.c.header
                || !lexical.c.rawEnding.isEmpty || lexical.c.preprocessor
                || lexical.json.blockComment || lexical.json.quote != nil
                || lexical.rust.depth > 0 || lexical.rust.lineComment
                || [13, 14, 21, 22, 24, 25].contains(lexical.rust.style)
                || [1, 2, 3, 13, 14, 15, 16].contains(lexical.powershell.mode)
            let tokens = scanner.highlight(
                String(decoding: source, as: UTF8.self),
                base: range.lower,
                state: &lexical
            )
            guard lexical.diagnostic == nil else {
                throw NateError.message(lexical.diagnostic ?? "结构字符缺少完整词法证据。")
            }
            var code = source
            for token in tokens where token.isStructureOpaque {
                for position in (token.range.lower - range.lower)..<(token.range.upper - range.lower) {
                    if position & 255 == 0 {
                        try Self.check(deadline: deadline, permit: permit)
                    }
                    code[position] = 32
                }
            }
            let targets = (byLine[line] ?? []).sorted {
                $0.selection.range.lower < $1.selection.range.lower
            }
            var cursor = 0
            for target in targets {
                let offset = target.selection.range.lower - range.lower
                try Self.scan(
                    code: code,
                    until: offset,
                    cursor: &cursor,
                    line: line,
                    array: array,
                    stack: &stack,
                    deadline: deadline,
                    permit: permit
                )
                // 同行多个目标若共同重写前缀会覆盖彼此输入，整行继续采用明确的字面字符。
                guard targets.count == 1, target.selection.range.isEmpty,
                    target.selection.virtualColumn == 0
                else {
                    continue
                }
                let origin: (line: Int, increase: Bool)?
                if input == "{" || input == "[" {
                    guard !startsOpaque,
                        source[..<offset].allSatisfy({
                            $0 == 9 || $0 == 32
                        }),
                        !tokens.contains(where: {
                            $0.isStructureOpaque && $0.range.lower <= target.selection.head
                                && target.selection.head < $0.range.upper
                        })
                    else {
                        continue
                    }
                    origin = previous
                }
                else if let opening = stack.last,
                    opening.byte == (input == "}" ? 123 : 91), opening.line < line
                {
                    // 只在插入点真正回到代码区后才调整行首，完整行的末状态不能替代光标处的状态。
                    guard
                        try StructuralInsertionContext.isCode(
                            source: source,
                            offset: offset,
                            base: range.lower,
                            initial: initial,
                            scanner: scanner,
                            language: language
                        )
                    else {
                        continue
                    }
                    origin = (opening.line, false)
                }
                else {
                    origin = nil
                }
                if let origin {
                    let prefix = try Self.prefix(
                        in: snapshot.text,
                        line: origin.line,
                        increase: origin.increase,
                        settings: settings,
                        remaining: &prefixBytes,
                        deadline: deadline,
                        permit: permit
                    )
                    output[target.id] = prefix
                }
            }
            try Self.scan(
                code: code,
                until: code.count,
                cursor: &cursor,
                line: line,
                array: array,
                stack: &stack,
                deadline: deadline,
                permit: permit
            )
            if source.contains(where: {
                ![9, 10, 13, 32].contains($0)
            }) {
                previous = (line, stack.last?.line == line)
            }
        }
        try Self.check(deadline: deadline, permit: permit)
        prefixes = output
    }

    /// 业务作用：核心只能取得同一来源和同一稳定选择的空白，旧词法计划不能扩张新输入范围。
    /// 参数说明:
    /// - entry: 核心重新确认的当前普通选择。
    /// - snapshot: 本轮输入事务的完整来源。
    /// 返回：有适用规则时为完整前导空白，否则为空；任何来源或选择变化均拒绝旧计划。
    public func prefix(for entry: SelectionEntry, snapshot: DocumentSnapshot) throws -> String? {
        try Self.check(deadline: deadline, permit: permit)
        guard snapshot.id == self.snapshot.id, snapshot.revision == self.snapshot.revision,
            snapshot.selectionGeneration == self.snapshot.selectionGeneration,
            entries[entry.id] == entry,
            try self.snapshot.text.byteEqual(
                to: snapshot.text,
                permit: {
                    permit() && ContinuousClock.now < deadline
                }
            )
        else {
            throw NateError.message("结构字符的原文或选择身份已经改变。")
        }
        return prefixes[entry.id]
    }

    /// 业务作用：顺序消费已遮蔽的不透明范围，实际代码栈不会跨越不相容的闭合符。
    /// 参数说明:
    /// - code: 当前行已遮蔽的完整原字节。
    /// - until: 当前目标或整行结束边界。
    /// - cursor: 本行已经消费的位置。
    /// - line: 当前原文物理行。
    /// - array: 是否启用 JSON 方括号。
    /// - stack: 所有前置行共同持有的未闭合代码开端。
    /// - deadline: 整批输入的共同截止。
    /// - permit: 当前仍有准备资格。
    /// 返回：完整推进到边界，过量嵌套或失权时失败。
    private static func scan(
        code: [UInt8],
        until: Int,
        cursor: inout Int,
        line: Int,
        array: Bool,
        stack: inout [(byte: UInt8, line: Int)],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws {
        while cursor < until {
            if cursor & 255 == 0 {
                try check(deadline: deadline, permit: permit)
            }
            let byte = code[cursor]
            if byte == 123 || array && byte == 91 {
                guard stack.count < 65_536 else {
                    throw NateError.message("结构字符的代码嵌套超过 65536 层。")
                }
                stack.append((byte, line))
            }
            else if byte == 125 || array && byte == 93 {
                if stack.last?.byte == (byte == 125 ? 123 : 91) {
                    stack.removeLast()
                }
                else {
                    // 不完整结构不能把更早开端误认为本次字符的配对证据。
                    stack.removeAll(keepingCapacity: true)
                }
            }
            cursor += 1
        }
    }

    /// 业务作用：沿完整原前导字节取得对齐依据，新增一级遵循当前语言的实际列宽。
    /// 参数说明:
    /// - text: 同一固定正文。
    /// - line: 已确认的开端或前一非空物理行。
    /// - increase: 是否在尚未闭合的前行开端内增加一级。
    /// - settings: 当前语言的 Tab 设置。
    /// - remaining: 全部目标已消耗的前缀读取及输出字节数。
    /// - deadline: 整批输入的共同截止。
    /// - permit: 当前仍有准备资格。
    /// 返回：至多 1 MiB 共享读取与输出、百万列以内的完整空白。
    private static func prefix(
        in text: PieceTree,
        line: Int,
        increase: Bool,
        settings: TabSettings,
        remaining: inout Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> String {
        let range = text.lineRange(line, includeEnding: false)
        var end = range.lower, column = 0
        while end < range.upper, let byte = text.byte(at: end), byte == 9 || byte == 32 {
            if end & 255 == 0 {
                try check(deadline: deadline, permit: permit)
            }
            remaining += 1
            column += byte == 9 ? settings.width - column % settings.width : 1
            guard remaining <= 1_048_576, column <= 1_000_000 else {
                throw NateError.message("结构字符的共享前缀超过 1 MiB 或一百万列。")
            }
            end += 1
        }
        var prefix = text.text(in: ByteRange(range.lower, end))
        if increase {
            guard column <= 1_000_000 - settings.width else {
                throw NateError.message("结构字符的新缩进超过一百万列。")
            }
            let extra =
                settings.useSpaces
                ? String(repeating: " ", count: settings.width)
                : "\t" + String(repeating: " ", count: column % settings.width)
            remaining += extra.utf8.count
            guard remaining <= 1_048_576 else {
                throw NateError.message("结构字符的共享前缀超过 1 MiB。")
            }
            prefix += extra
        }
        return prefix
    }

    /// 业务作用：结构扫描与查询沿同一控制资格和截止，不为后续光标重新授予运行时间。
    /// 参数说明:
    /// - deadline: 本次完整输入的共同截止。
    /// - permit: 当前仍有完整准备资格。
    /// 返回：资格有效时继续，取消或截止时拒绝整批输入。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("结构字符输入已取消或超过共同截止。")
        }
    }
}
