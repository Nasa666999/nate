import Foundation
import NateCore

struct JSONLexing {
    let bytes: [UInt8]
    let base: Int
    let extended: Bool
    let rules: UnicodeIdentifierRules?
    var state: JSONLexicalState
    var budget: JSONLexingBudget
    var cursor = 0
    var tokens: [SyntaxToken] = []

    /// 业务作用：逐行推进独立 JSON 状态，仅在整行有完整执行资格时发布呈现与检查点。
    /// 参数说明:
    /// - text: 当前完整逻辑行，包含原始结束符。
    /// - base: 原始快照中的行首字节位置。
    /// - extended: 是否启用 JSON5 规则。
    /// - rules: JSON5 固定 Unicode 标识符范围。
    /// - deadline: 整次快照分析共用的截止。
    /// - state: 前一完整行的状态，失败时只记录诊断。
    /// 返回：完整行的有界词法范围；容量、取消或状态不一致时不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        extended: Bool,
        rules: UnicodeIdentifierRules?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        // 未确认输入范围或模式身份时不能继续传播旧检查点，避免结构索引采用错误上下文。
        guard text.utf8.count <= 1_048_576, base >= 0,
            base <= Int.max - text.utf8.count,
            state.json.extended == nil || state.json.extended == extended
        else {
            state.diagnostic = "JSON 高亮暂停：行范围、容量或语言检查点不一致。"
            return []
        }
        do {
            let budget = JSONLexingBudget(deadline: deadline)
            try budget.check()
            var scanner = JSONLexing(
                bytes: Array(text.utf8),
                base: base,
                extended: extended,
                rules: rules,
                state: state.json,
                budget: budget
            )
            scanner.state.extended = extended
            try scanner.scan()
            try scanner.budget.check()
            // 完整扫描和末次取消复验先于状态发布，超限不能留下半行容器或字符串状态。
            state.json = scanner.state
            return scanner.tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：按字符串、注释和容器上下文解释源字节，字面括号不进入代码结构。
    /// 参数说明: 无。
    /// 返回：扫描完整当前行，资源上限失败时抛错供调用方舍弃全部中间结果。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            if state.quote != nil {
                try stringByte()
                continue
            }
            if state.lineComment || state.blockComment {
                try commentByte()
                continue
            }
            let byte = bytes[cursor]
            if whitespaceWidth(at: cursor) > 0 {
                cursor += whitespaceWidth(at: cursor)
            }
            else if byte == 34 || byte == 39 {
                state.quote = byte
                state.propertyString = state.expectsProperty
                state.consumeProperty()
                try emit(cursor, cursor + 1, kind: .string, style: stringStyle)
                cursor += 1
            }
            else if extended, byte == 47, cursor + 1 < bytes.count,
                bytes[cursor + 1] == 47 || bytes[cursor + 1] == 42
            {
                state.lineComment = bytes[cursor + 1] == 47
                state.blockComment = !state.lineComment
                state.blockStar = false
                try emit(cursor, cursor + 2, kind: .comment, style: "comment")
                cursor += 2
            }
            else if "{}[],:".utf8.contains(byte) {
                try structure(byte)
                try emit(cursor, cursor + 1, kind: .punctuation, style: "punctuation")
                cursor += 1
            }
            else {
                try word()
            }
        }
    }

    /// 业务作用：限制对象与数组的上下文深度，属性类别不能串入外层或超过固定状态容量。
    /// 参数说明:
    /// - byte: 当前容器标点。
    /// 返回：合法配对推进栈；不匹配的源码标点不弹出其它容器，深度超限抛错。
    mutating func structure(_ byte: UInt8) throws {
        switch byte {
        case 123, 91:
            guard state.containers.count < 1024 else {
                throw NateError.message("JSON 高亮暂停：容器嵌套超过 1024 层。")
            }
            state.consumeProperty()
            state.containers.append(byte == 123 ? .object(expectingKey: true) : .array)
        case 125:
            if case .object? = state.containers.last {
                state.containers.removeLast()
            }
        case 93:
            if case .array? = state.containers.last {
                state.containers.removeLast()
            }
        case 44:
            if case .object? = state.containers.last {
                state.containers[state.containers.count - 1] = .object(expectingKey: true)
            }
        case 58:
            state.consumeProperty()
        default:
            break
        }
    }

    /// 业务作用：完整候选只获一种名称、关键字或数值身份，非法尾部不被拆成合法数值前缀。
    /// 参数说明: 无。
    /// 返回：推进至少一个完整标量，预算失败不发布候选。
    mutating func word() throws {
        let start = cursor
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if whitespaceWidth(at: cursor) > 0 || "{}[],:\"'/".utf8.contains(byte) {
                break
            }
            try budget.consume()
            cursor += scalarWidth(at: cursor)
        }
        if cursor == start {
            cursor += scalarWidth(at: cursor)
        }
        let candidate = bytes[start..<cursor]
        if state.expectsProperty {
            let valid = try extended && identifier(candidate)
            try emit(start, cursor, kind: .string, style: valid ? "property" : "invalid")
            state.consumeProperty()
        }
        else if candidate.elementsEqual("true".utf8) || candidate.elementsEqual("false".utf8)
            || candidate.elementsEqual("null".utf8)
        {
            try emit(start, cursor, kind: .keyword, style: "keyword")
        }
        else {
            let valid = try JSONNumbers.valid(candidate, extended: extended, budget: &budget)
            try emit(start, cursor, kind: valid ? .number : .text, style: valid ? "number" : "invalid")
        }
    }

    /// 业务作用：保留原字节坐标和独立词法身份，连续相同片段合并以约束呈现容量。
    /// 参数说明:
    /// - start: 行内起点。
    /// - end: 行内结束边界。
    /// - kind: 供结构分析使用的基础类别。
    /// - style: JSON 内部词法类别。
    /// 返回：非空范围进入结果；超过 65536 个独立片段时拒绝整行。
    mutating func emit(_ start: Int, _ end: Int, kind: SyntaxKind, style: String) throws {
        guard end > start else {
            return
        }
        let identity = "json:" + style
        if let last = tokens.last, last.range.upper == base + start,
            last.kind == kind, last.lexicalStyle == identity
        {
            tokens[tokens.count - 1] = SyntaxToken(
                range: ByteRange(last.range.lower, base + end),
                kind: kind,
                lexicalStyle: identity
            )
            return
        }
        guard tokens.count < 65_536 else {
            throw NateError.message("JSON 高亮暂停：单行词法片段超过 65536 个。")
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(base + start, base + end),
                kind: kind,
                lexicalStyle: identity
            )
        )
    }
}
