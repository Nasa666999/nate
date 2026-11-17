import Foundation
import NateCore

public struct BracketMatch: Sendable, Equatable {
    public let position: Int
    public let partner: Int?
}

public struct StructuralBracketPair: Sendable {
    public let range: ByteRange
    public let opener: UInt8
}

public struct BracketAnalysisLimits: Sendable {
    public var maximumBytes: Int
    public var maximumLineBytes: Int
    public var maximumBrackets: Int
    public var time: Duration

    /// 业务作用：为括号结构分析限定正文、单行、结果数量和处理时间，超限不发布部分匹配。
    /// 参数说明:
    /// - maximumBytes: 本次正文的总字节预算。
    /// - maximumLineBytes: 单行词法解析的字节预算。
    /// - maximumBrackets: 允许保留的括号位置数量。
    /// - time: 当前分析在检查边界内的处理预算。
    /// 返回：可由调用方明确配置的分析边界。
    public init(
        maximumBytes: Int = 67_108_864,
        maximumLineBytes: Int = 1_048_576,
        maximumBrackets: Int = 262_144,
        time: Duration = .seconds(5)
    ) {
        self.maximumBytes = maximumBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumBrackets = maximumBrackets
        self.time = time
    }
}

private struct BracketClass: Hashable {
    let opener: UInt8
    let style: String
}

public struct BracketIndex: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let structuralPairs: [StructuralBracketPair]
    private let entries: [Int: BracketMatch]

    /// 业务作用：在完整快照上按括号类型和当前词法样式分别配对，保留未匹配位置用于明确反馈。
    /// 参数说明:
    /// - snapshot: 本次分析的已提交原始正文。
    /// - language: 当前语言定义，为空时按纯文本识别。
    /// - udl: 当前独立 UDL，为空时采用内置词法。
    /// - limits: 结果和计算预算。
    /// 返回：绑定原文档与修订的完整索引；取消、超限或单行无法完整解析时不发布部分结果。
    public init(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition? = nil,
        udl: UDLDefinition? = nil,
        limits: BracketAnalysisLimits = BracketAnalysisLimits()
    ) throws {
        guard limits.maximumBytes >= 0, limits.maximumLineBytes > 0,
            limits.maximumBrackets > 0, limits.time > .zero,
            snapshot.text.byteCount <= limits.maximumBytes
        else {
            throw NateError.message("括号匹配暂停：正文超过当前分析预算，或预算配置无效。")
        }
        let scanner = language.map(SyntaxScanner.init)
        var native = SyntaxState()
        var user = UDLState()
        var stacks: [BracketClass: [Int]] = [:]
        var output: [Int: BracketMatch] = [:]
        var pairs: [StructuralBracketPair] = []
        let deadline = ContinuousClock.now.advanced(by: limits.time)
        let plain = udl == nil ? SyntaxKind.text.rawValue : "udl:DEFAULT"
        for line in 0..<snapshot.text.lineCount {
            try Self.check(deadline)
            let range = snapshot.text.lineRange(line)
            guard range.count <= limits.maximumLineBytes else {
                throw NateError.message("括号匹配暂停：单行超过当前词法解析预算。")
            }
            let text = snapshot.text.text(in: range)
            let tokens =
                udl.map {
                    UDLLexer.highlight(text, base: range.lower, definition: $0, state: &user)
                } ?? scanner?.highlight(text, base: range.lower, state: &native) ?? []
            if let diagnostic = native.diagnostic {
                // 词法状态失去完整证据时不能把余下字符串或表达式当成可导航结构。
                throw NateError.message(diagnostic)
            }
            let ordered = tokens.sorted {
                $0.range.lower < $1.range.lower
            }
            var tokenIndex = 0
            for (offset, byte) in text.utf8.enumerated() {
                if offset & 16_383 == 0 {
                    try Self.check(deadline)
                }
                guard let opener = Self.opener(for: byte) else {
                    continue
                }
                guard output.count < limits.maximumBrackets else {
                    throw NateError.message("括号匹配暂停：括号位置数量超过当前预算。")
                }
                let position = range.lower + offset
                while tokenIndex < ordered.count && ordered[tokenIndex].range.upper <= position {
                    tokenIndex += 1
                }
                var style = plain
                var kind = SyntaxKind.text
                if tokenIndex < ordered.count, ordered[tokenIndex].range.lower <= position {
                    let token = ordered[tokenIndex]
                    style = token.lexicalStyle
                    kind = token.kind
                }
                let key = BracketClass(
                    opener: opener,
                    style: style
                )
                if byte == opener {
                    stacks[key, default: []].append(position)
                    output[position] = BracketMatch(
                        position: position,
                        partner: nil
                    )
                }
                else if let previous = stacks[key]?.popLast() {
                    // 每种括号独立计数，词法样式不同的字符不能互相消耗配对深度。
                    output[position] = BracketMatch(
                        position: position,
                        partner: previous
                    )
                    output[previous] = BracketMatch(
                        position: previous,
                        partner: position
                    )
                    if kind != .comment && kind != .string {
                        pairs.append(
                            StructuralBracketPair(
                                range: ByteRange(previous, position + 1),
                                opener: opener
                            )
                        )
                    }
                }
                else {
                    output[position] = BracketMatch(
                        position: position,
                        partner: nil
                    )
                }
            }
        }
        try Self.check(deadline)
        documentID = snapshot.id
        revision = snapshot.revision
        entries = output
        structuralPairs = pairs
    }

    /// 业务作用：按光标前字符优先的编辑器习惯选择当前括号，字节位置不与 UTF-16 下标混用。
    /// 参数说明:
    /// - caret: 已验证的原始正文光标字节位置。
    /// 返回：邻接括号及其可选配对，附近没有括号时为空。
    public func match(at caret: Int) -> BracketMatch? {
        if caret > 0, let before = entries[caret - 1] {
            return before
        }
        return entries[caret]
    }

    /// 业务作用：为选择内部文本定位包围当前光标的最小完整括号范围。
    /// 参数说明:
    /// - caret: 当前原始正文光标位置。
    /// 返回：最近的完整包围范围，不包含两端括号；没有完整包围时为空。
    public func interior(at caret: Int) -> ByteRange? {
        if let adjacent = match(at: caret) {
            guard let partner = adjacent.partner else {
                return nil
            }
            return ByteRange(
                min(adjacent.position, partner) + 1,
                max(adjacent.position, partner)
            )
        }
        var nearest: ByteRange?
        for (position, entry) in entries {
            guard let partner = entry.partner, position < partner, position < caret, caret <= partner else {
                continue
            }
            let candidate = ByteRange(
                position + 1,
                partner
            )
            if let current = nearest {
                if candidate.count < current.count
                    || (candidate.count == current.count && candidate.lower > current.lower)
                {
                    nearest = candidate
                }
            }
            else {
                nearest = candidate
            }
        }
        return nearest
    }

    /// 业务作用：快速判断光标邻接字符是否可触发括号分析，不复制整行或全文。
    /// 参数说明:
    /// - tree: 当前原始正文。
    /// - caret: 当前合法字节边界。
    /// 返回：前方或后方具有圆括号、方括号或花括号时为真。
    public static func isAdjacent(in tree: PieceTree, caret: Int) -> Bool {
        guard tree.isBoundary(caret) else {
            return false
        }
        return (caret > 0 && tree.byte(at: caret - 1).flatMap(opener) != nil)
            || tree.byte(at: caret).flatMap(opener) != nil
    }

    /// 业务作用：将两端字符归入同一括号类型，角括号留给标记语言结构规则处理。
    /// 参数说明:
    /// - byte: 当前 UTF-8 原始字节。
    /// 返回：圆、方或花括号的起始字节，其它字节为空。
    private static func opener(for byte: UInt8) -> UInt8? {
        switch byte {
        case 40, 41: return 40
        case 91, 93: return 91
        case 123, 125: return 123
        default: return nil
        }
    }

    /// 业务作用：在行和有界字节边界响应取消与截止，不把未完成配对作为完整索引发布。
    /// 参数说明:
    /// - deadline: 本次完整分析的截止时刻。
    /// 返回：仍有权限与预算时继续，否则抛错并丢弃未发布索引。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("括号匹配暂停：当前分析已超过处理时间预算。")
        }
    }
}
