import Foundation
import NateCore

enum LispIndentationPlan {
    private static let delimiters: Set<UInt8> = [40, 41, 91, 93, 123, 125]

    private struct Frame {
        let closing: UInt8
        let prefix: ByteRange
    }

    /// 业务作用：Lisp 和 Scheme 根据原生词法确认仍开放的真实列表，全部光标共用同一原文及输入预算。
    /// 参数说明:
    /// - snapshot: 当前所有换行目标固定的不可变正文。
    /// - language: 实际 Lisp 或 Scheme 模式，决定真实词法资源。
    /// - ranges: 已验证的普通或矩形真实替换范围。
    /// - deadline: 词法、缩进及提交共用的实际截止。
    /// - permit: 当前编辑请求继续有效的资格。
    /// 返回：完整的逐目标结构动作；未知读取语法内沿用原缩进，容量或词法失效时整批停止。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：全部前置语法与多光标准备共用一次编辑期限。
        /// 参数说明: 无。
        /// 返回：资格仍有效时继续；取消或超时不交付任何部分计划。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Lisp 结构缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var byLine: [Int: [ByteRange]] = [:]
        for target in ranges {
            try check()
            byLine[text.lineNumber(at: target.lower), default: []].append(target)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Lisp 结构缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        let operatorStyle = language.id + ":10"
        let blockStyle = language.id + ":12"
        var lexical = SyntaxState()
        var stack: [Frame] = []
        var prefixes: [ByteRange: String] = [:]
        var remainingSource = 64 * 1_048_576
        var remainingPrefixes = 1_048_576
        var actions: [ByteRange: NewlineIndentationAction] = [:]
        var safe = true

        /// 业务作用：原始混合空白可供多个缩进目标共享，先确认共同容量再复制来源。
        /// 参数说明:
        /// - range: 已知开端所在物理行的原始水平空白。
        /// 返回：确切前缀；超限时停止本次全部结构动作。
        func prefix(_ range: ByteRange) throws -> String {
            if let value = prefixes[range] {
                return value
            }
            guard range.count <= remainingPrefixes else {
                throw NateError.message("Lisp 结构缩进需要的完整原前缀超过 1 MiB。")
            }
            remainingPrefixes -= range.count
            let value = text.text(in: range)
            prefixes[range] = value
            return value
        }

        for line in 0...last {
            try check()
            let physical = text.lineRange(line)
            let body = text.lineRange(line, includeEnding: false)
            // 后续光标也要使用整段词法来源；任何前置行超量都不能授权较早的部分动作。
            guard physical.count <= 1_048_576, physical.count <= remainingSource else {
                throw NateError.message("Lisp 结构缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remainingSource -= physical.count
            let source = text.text(in: physical)
            let priorMode = lexical.lisp.style
            let tokens = scanner.highlight(source, base: physical.lower, state: &lexical)
            if let error = lexical.diagnostic {
                throw NateError.message(error)
            }
            let row = Array(source.utf8.prefix(body.count))
            let indentationEnd = try spaces(in: row, beginning: 0, check: check)
            let indentation = ByteRange(body.lower, body.lower + indentationEnd)
            let targets = byLine[line] ?? []
            let ordered = targets.sorted { $0.lower < $1.lower }

            var suffix: [ByteRange: Int] = [:]
            var after = 0
            for target in targets.sorted(by: { $0.upper < $1.upper }) where target.upper < body.upper {
                try check()
                after = try spaces(in: row, beginning: max(after, target.upper - body.lower), check: check)
                if after < row.count {
                    suffix[target] = after
                }
            }

            var operators: [Int: UInt8] = [:]
            for token in tokens where token.lexicalStyle == operatorStyle {
                try check()
                let lower = max(body.lower, token.range.lower)
                let upper = min(body.upper, token.range.upper)
                guard lower < upper else {
                    continue
                }
                for index in lower..<upper {
                    if index & 255 == 0 {
                        try check()
                    }
                    let offset = index - body.lower
                    let byte = row[offset]
                    if Self.delimiters.contains(byte) {
                        // 容量必须先于插入索引确认，不能用上一段检查授权本行其它目标。
                        guard operators.count < 65_536 else {
                            throw NateError.message("Lisp 结构缩进涉及超过 65536 个同行括号。")
                        }
                        operators[offset] = byte
                    }
                }
            }
            var tokenIndex = 0
            var targetIndex = 0
            var blockOpen = priorMode == 12
            var lastClosed: Frame?
            for position in 0...row.count {
                if position & 255 == 0 {
                    try check()
                }
                let absolute = body.lower + position
                while tokenIndex < tokens.count && tokens[tokenIndex].range.upper <= absolute {
                    tokenIndex += 1
                }
                let token =
                    tokenIndex < tokens.count && tokens[tokenIndex].range.lower <= absolute
                    ? tokens[tokenIndex] : nil
                let opaque = token?.isStructureOpaque == true
                let byte = position < row.count ? row[position] : 0
                let next = position + 1 < row.count ? row[position + 1] : 0
                if safe {
                    // 嵌套块注释、转义名称与忽略整个表达式需要额外读取状态，未获证明的括号不能改变当前或后续缩进。
                    let blockBoundary = token?.lexicalStyle == blockStyle
                    let opensBlock = blockBoundary && byte == 35 && next == 124
                    let closesBlock = blockBoundary && byte == 124 && next == 35
                    let nestedComment = opensBlock && blockOpen
                    if opensBlock {
                        blockOpen = true
                    }
                    else if closesBlock {
                        blockOpen = false
                    }
                    let ambiguousSymbol =
                        !opaque && (byte == 124 || byte == 92 && token?.lexicalStyle != language.id + ":11")
                    let discardedDatum = !opaque && byte == 35 && next == 59
                    if nestedComment || ambiguousSymbol || discardedDatum {
                        safe = false
                    }
                }

                while targetIndex < ordered.count
                    && min(body.count, ordered[targetIndex].lower - body.lower) == position
                {
                    let target = ordered[targetIndex]
                    let offset = suffix[target]
                    let right = offset.flatMap { operators[$0] }
                    let continued = token?.range.lower == body.lower && [6, 12].contains(priorMode)
                    let inside =
                        opaque && (token?.range.lower != absolute || continued)
                        || position == row.count && [1, 6, 12].contains(lexical.lisp.style)
                    let action: NewlineIndentationAction
                    if !safe || inside {
                        action = .inherit
                    }
                    else if let frame = stack.last {
                        let original = try prefix(frame.prefix)
                        action =
                            right == frame.closing
                            ? .expandAlignedPair(prefix: original) : .align(prefix: original, levels: 1)
                    }
                    else if let lastClosed {
                        action = .align(prefix: try prefix(lastClosed.prefix), levels: 0)
                    }
                    else {
                        action = .inherit
                    }
                    actions[target] = action
                    targetIndex += 1
                }
                guard safe, let actual = operators[position] else {
                    if position < row.count, !opaque, byte != 32, byte != 9 {
                        lastClosed = nil
                    }
                    continue
                }
                if let closer = closing(for: actual) {
                    guard stack.count < 4096 else {
                        throw NateError.message("Lisp 结构缩进超过 4096 层活动列表。")
                    }
                    stack.append(Frame(closing: closer, prefix: indentation))
                    lastClosed = nil
                }
                else if let frame = stack.last, frame.closing == actual {
                    lastClosed = stack.removeLast()
                }
                else {
                    // 已损坏的括号关系不能把上一个外层错当作新行开端。
                    stack.removeAll()
                    lastClosed = nil
                }
            }
        }
        try check()
        return actions
    }

    /// 业务作用：替换后只隔原空格或 Tab 的闭合符可以保留成对换行资格。
    /// 参数说明:
    /// - row: 同一物理行中已经固定的原字节。
    /// - beginning: 本次选区结束后的实际相对起点。
    /// - check: 所有目标共享的时间与取消检查。
    /// 返回：同一行首个非水平空白字节或真实行尾。
    private static func spaces(in row: [UInt8], beginning: Int, check: () throws -> Void) throws -> Int {
        var position = beginning
        while position < row.count, row[position] == 32 || row[position] == 9 {
            if position & 255 == 0 {
                try check()
            }
            position += 1
        }
        return position
    }

    /// 业务作用：在原生词法确认后为当前列表选择确切的闭合字节。
    /// 参数说明:
    /// - character: 当前已经确认是实际操作符的原字节。
    /// 返回：当前开端对应的闭合类型；闭合符没有下层开端类型。
    private static func closing(for character: UInt8) -> UInt8? {
        switch character {
        case 40: 41
        case 91: 93
        case 123: 125
        default: nil
        }
    }
}
