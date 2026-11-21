import Foundation
import NateCore

public struct StructuralIndentationPlan: Sendable {
    private let documentID: UUID
    private let revision: UInt64
    private let selectionGeneration: UUID?
    private let source: PieceTree
    private let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private let actions: [ByteRange: NewlineIndentationAction]
    public let usesLanguageRules: Bool

    /// 业务作用：在同一正文的行间词法状态上，为全部换行目标确认结构动作，不按裸括号猜测字符串内容。
    /// 参数说明:
    /// - snapshot: 与完整目标属于同一来源的固定正文。
    /// - language: 当前内置语言，缺少适用规则时继承原缩进。
    /// - udl: 当前用户语言，尚无结构规则时继承原缩进。
    /// - ranges: 全部已归并或原生证明的真实替换范围。
    /// - deadline: 输入动作从开始准备到最终提交共同拥有的截止。
    /// - permit: 当前输入动作继续准备的资格。
    /// 返回：有界且不可变的逐目标动作；词法状态、容量或来源边界不足时整体失败。
    public init(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition?,
        udl: UDLDefinition?,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Self.check(deadline: deadline, permit: permit)
        guard !ranges.isEmpty, ranges.count <= 100_000 else {
            throw NateError.message("语言缩进需要一至十万个完整目标。")
        }
        for range in ranges {
            try Self.check(deadline: deadline, permit: permit)
            guard range.lower >= 0, range.upper >= range.lower,
                snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper)
            else {
                throw NateError.invalidRange
            }
        }
        documentID = snapshot.id
        revision = snapshot.revision
        selectionGeneration = snapshot.selectionGeneration
        source = snapshot.text
        self.deadline = deadline
        self.permit = permit
        let identifier = language?.id ?? "normal"
        let curly: Set<String> = [
            "c", "cpp", "java", "cs", "objc", "php", "javascript", "javascript.js", "jsp", "css",
            "perl", "rust", "powershell", "json", "json5", "typescript", "go", "swift",
        ]
        usesLanguageRules = udl == nil && (identifier == "python" || curly.contains(identifier))
        guard usesLanguageRules, let language else {
            actions = Dictionary(
                ranges.map {
                    ($0, .inherit)
                },
                uniquingKeysWith: {
                    first,
                    _ in first
                }
            )
            return
        }
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            byLine[snapshot.text.lineNumber(at: range.lower), default: []].append(range)
        }
        let lastLine = byLine.keys.max() ?? 0
        guard lastLine < 1_048_576 else {
            throw NateError.message("语言缩进的前置词法传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot)
        var state = SyntaxState()
        var output: [ByteRange: NewlineIndentationAction] = [:]
        var consumed = 0
        for line in 0...lastLine {
            try Self.check(deadline: deadline, permit: permit)
            let row = snapshot.text.lineRange(line)
            guard row.count <= 1_048_576, row.count <= 67_108_864 - consumed else {
                throw NateError.message("语言缩进超过单行 1 MiB 或前置原文 64 MiB，未准备部分输入。")
            }
            consumed += row.count
            let source = snapshot.text.text(in: row)
            let startsInBlockComment = !state.blockEnd.isEmpty || state.json.blockComment
            let tokens = scanner.highlight(source, base: row.lower, state: &state)
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "语言缩进缺少完整词法状态。")
            }
            guard let targets = byLine[line] else {
                continue
            }
            var code = Array(source.utf8)
            for token in tokens where token.kind == .comment || token.kind == .string {
                let lower = token.range.lower - row.lower
                let upper = token.range.upper - row.lower
                // 字符串是完整的不透明表达式，不能把它移除后让前面的块标点冒充行尾；注释不制造代码。
                let replacement: UInt8 = token.kind == .comment ? 32 : 127
                for index in lower..<upper {
                    if index & 255 == 0 {
                        try Self.check(deadline: deadline, permit: permit)
                    }
                    code[index] = replacement
                }
            }
            var significant: [Int] = []
            for index in code.indices {
                if index & 255 == 0 {
                    try Self.check(deadline: deadline, permit: permit)
                }
                if ![9, 10, 13, 32].contains(code[index]) {
                    significant.append(index)
                }
            }
            for target in targets {
                try Self.check(deadline: deadline, permit: permit)
                let offset = target.lower - row.lower
                let before = Self.previous(significant, before: offset)
                let last = before.map {
                    code[$0]
                }
                let following = snapshot.text.byte(at: target.upper)
                let token = Self.token(before: target.lower, in: tokens)
                let nextToken = Self.token(before: target.lower + 1, in: tokens)
                let insideString =
                    token?.kind == .string
                    && ((token?.range.upper ?? 0) > target.lower || nextToken?.kind == .string)
                let insideBlockComment: Bool
                if let token, token.kind == .comment {
                    let marker = language.lineComment
                    let lineComment =
                        !(startsInBlockComment && token.range.lower == row.lower)
                        && !marker.isEmpty
                        && snapshot.text.text(
                            in: ByteRange(
                                token.range.lower,
                                min(token.range.upper, token.range.lower + marker.utf8.count)
                            )
                        ).hasPrefix(marker)
                    let closing = language.blockEnd
                    let alreadyClosed =
                        token.range.upper == target.lower && !closing.isEmpty
                        && target.lower - token.range.lower >= closing.utf8.count
                        && snapshot.text.text(in: ByteRange(target.lower - closing.utf8.count, target.lower))
                            == closing
                    insideBlockComment = !lineComment && !alreadyClosed
                }
                else {
                    insideBlockComment = false
                }
                if insideString || insideBlockComment {
                    output[target] = .inherit
                }
                else if identifier == "python" {
                    output[target] = last == 58 ? .increase : .inherit
                }
                else {
                    let array = identifier == "json" || identifier == "json5"
                    let opener: UInt8? = last == 123 ? 125 : (array && last == 91 ? 93 : nil)
                    if let closer = opener {
                        output[target] = following == closer ? .expandPair : .increase
                    }
                    else if following == 125 || array && following == 93 {
                        output[target] = .decrease
                    }
                    else {
                        output[target] = .inherit
                    }
                }
            }
        }
        try Self.check(deadline: deadline, permit: permit)
        actions = output
    }

    /// 业务作用：核心事务只能读取同一快照及完整范围已经确认的结构动作，来源改变不能沿旧规则写入。
    /// 参数说明:
    /// - target: 核心已经验证的实际换行目标。
    /// - snapshot: 本轮核心事务使用的完整来源。
    /// 返回：对应完整动作；文档、修订、选择代次或范围不符时抛错。
    public func action(for target: NewlineInsertionTarget, snapshot: DocumentSnapshot) throws
        -> NewlineIndentationAction
    {
        try Self.check(deadline: deadline, permit: permit)
        // 同一身份字段不能代替原字节证据；共享树可直接确认，其它输入仍沿原截止完整比较。
        guard snapshot.id == documentID, snapshot.revision == revision,
            snapshot.selectionGeneration == selectionGeneration,
            try source.byteEqual(
                to: snapshot.text,
                permit: {
                    permit() && ContinuousClock.now < deadline
                }
            ),
            let action = actions[target.range]
        else {
            throw NateError.message("语言缩进来源或完整目标已改变，未提交旧动作。")
        }
        return action
    }

    /// 业务作用：同一长行上的多个光标复用实际代码位置索引，空白前缀不被逐目标重复扫描。
    /// 参数说明:
    /// - offsets: 当前行有序的非空白代码字节位置。
    /// - position: 当前真实插入边界。
    /// 返回：边界前的最后代码位置，没有前置代码时为空。
    private static func previous(_ offsets: [Int], before position: Int) -> Int? {
        var lower = 0, upper = offsets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if offsets[middle] < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower > 0 ? offsets[lower - 1] : nil
    }

    /// 业务作用：同一行的多个光标以有序词法范围查询上下文，不逐光标遍历整份词元列表。
    /// 参数说明:
    /// - position: 已确认的原文插入边界。
    /// - tokens: 当前行按原文顺序产生的完整词法范围。
    /// 返回：覆盖边界前一个字节的词元，没有呈现片段时为空。
    private static func token(before position: Int, in tokens: [SyntaxToken]) -> SyntaxToken? {
        var lower = 0, upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].range.lower < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower > 0, tokens[lower - 1].range.upper >= position else {
            return nil
        }
        return tokens[lower - 1]
    }

    /// 业务作用：词法传播、目标分类与发布准备共用截止，取消不能只舍弃部分光标。
    /// 参数说明:
    /// - deadline: 本次输入的共同截止。
    /// - permit: 当前继续准备的资格。
    /// 返回：仍有完整资格时继续，否则抛错并保留全部原状态。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("语言缩进已取消或超过共同截止，正文与选择保持原状。")
        }
    }
}
