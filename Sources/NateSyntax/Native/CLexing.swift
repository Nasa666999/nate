import Foundation
import NateCore

struct CLexing {
    let bytes: [UInt8]
    let base: Int
    let keywords: Set<String>
    let secondaryKeywords: Set<String>
    let documentationKeywords: Set<String>
    let snapshot: DocumentSnapshot?
    let unicodeLineEnding: Bool
    var state: CLexicalState
    var budget: CLexingBudget
    var cursor = 0
    var literalStart = 0
    var tokens: [SyntaxToken] = []

    /// 业务作用：逐行推进独立 C/C++ 词法状态，整行有完整资格后才发布呈现和后续检查点。
    /// 参数说明:
    /// - text: 完整原始逻辑行，包含实际结束符。
    /// - base: 当前行在原快照中的 UTF-8 起点。
    /// - language: 当前固定的 C 或 C++ 模式身份。
    /// - keywords: 当前语言的主要关键字集合。
    /// - secondaryKeywords: 当前语言的次要关键字集合。
    /// - documentationKeywords: 当前语言明确定义的文档注释命令集合。
    /// - snapshot: XML 名称跨物理行时固定向前证据的完整正文快照。
    /// - deadline: 本次固定快照分析的共同截止。
    /// - state: 前一完整行的独立状态，失败时只设置诊断。
    /// 返回：完整有界词元；范围、模式、容量、取消或截止失败均不发布部分状态。
    static func highlight(
        _ text: String,
        base: Int,
        language: String,
        keywords: Set<String>,
        secondaryKeywords: Set<String>,
        documentationKeywords: Set<String>,
        snapshot: DocumentSnapshot? = nil,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        // 旧模式或不完整范围没有传播资格，结构分析不能继续使用来源不明的检查点。
        guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
            state.c.language == nil || state.c.language == language
        else {
            state.diagnostic = "C/C++ 高亮暂停：行范围、容量或语言检查点不一致。"
            return []
        }
        do {
            let budget = CLexingBudget(deadline: deadline)
            try budget.check()
            var scanner = CLexing(
                bytes: Array(text.utf8),
                base: base,
                keywords: keywords,
                secondaryKeywords: secondaryKeywords,
                documentationKeywords: documentationKeywords,
                snapshot: snapshot,
                unicodeLineEnding: text.hasSuffix("\u{0085}") || text.hasSuffix("\u{2028}")
                    || text.hasSuffix("\u{2029}"),
                state: state.c,
                budget: budget
            )
            scanner.state.language = language
            try scanner.scan()
            try scanner.budget.check()
            // 完整遍历和末次取消复验先于状态发布，失败不能留下半行注释、原始字面或预处理上下文。
            state.c = scanner.state
            return scanner.tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：按原始字面、注释、续行与预处理上下文解释源字节，字面标点不进入代码结构。
    /// 参数说明: 无。
    /// 返回：完整推进当前行；资源失败向调用方抛错以舍弃全部中间结果。
    mutating func scan() throws {
        if let pending = state.xmlContinuation {
            // 跨行名称的样式依赖最初快照，另一修订不能承接已经读取的后续证据。
            guard let snapshot, pending.documentID == snapshot.id,
                pending.revision == snapshot.revision, pending.nextOffset == base,
                pending.endOffset >= base, base <= snapshot.text.byteCount - bytes.count,
                snapshot.text.isBoundary(base), snapshot.text.isBoundary(base + bytes.count),
                snapshot.text.bytes(in: ByteRange(base, base + bytes.count)).elementsEqual(bytes)
            else {
                throw NateError.message("C/C++ 文档 XML 名称的连续范围或快照已改变。")
            }
            let end = min(bytes.count, pending.endOffset - base)
            let previous = base > 0 ? snapshot.text.byte(at: base - 1) : nil
            let endingWidth = previous == 10 && base >= 2 && snapshot.text.byte(at: base - 2) == 13 ? 2 : 1
            let spliced = base > endingWidth && snapshot.text.byte(at: base - endingWidth - 1) == 92
            if !spliced, previous == 10 || previous == 13 && snapshot.text.byte(at: base) != 10 {
                // XML 名称仍持有行注释身份，但新物理行必须解除上一行的预处理与词元上下文。
                let lineComment = state.lineComment
                endLogicalLine()
                state.lineComment = lineComment
            }
            try emit(0, end, kind: .comment, style: pending.style)
            cursor = end
            if end == pending.endOffset - base {
                state.xmlContinuation = nil
                if pending.closesBlock {
                    state.blockComment = false
                    state.documentation = false
                }
            }
            else {
                let nextOffset = base + bytes.count
                state.xmlContinuation?.nextOffset = nextOffset
            }
        }
        while cursor < bytes.count {
            try budget.consume()
            if state.verbatim {
                try verbatimByte()
                continue
            }
            if !state.rawEnding.isEmpty {
                try rawByte()
                continue
            }
            if state.skipSplicedLineFeed {
                state.skipSplicedLineFeed = false
                if bytes[cursor] == 10 {
                    try emitContext(cursor, cursor + 1)
                    cursor += 1
                    continue
                }
            }
            let splice = spliceWidth(at: cursor)
            if splice > 0 {
                try emitContext(cursor, cursor + splice)
                // 块注释只接受原文中相邻的结束符；物理续行不能把分隔两行的星号与斜线拼成结束符。
                state.blockStar = false
                state.splicedWord = false
                state.skipSplicedLineFeed = bytes[cursor + 1] == 13 && splice == 2
                cursor += splice
                continue
            }
            if state.quote != nil || state.header {
                try quotedByte()
                continue
            }
            if state.blockComment || state.lineComment {
                try commentByte()
                continue
            }
            let ending = newlineWidth(at: cursor)
            if ending > 0 {
                endLogicalLine()
                cursor += ending
                continue
            }
            let byte = bytes[cursor]
            if try continueToken() {
                continue
            }
            if [9, 11, 12, 32].contains(byte) {
                cursor += 1
            }
            else if cursor + 1 < bytes.count, byte == 47, bytes[cursor + 1] == 47 || bytes[cursor + 1] == 42 {
                state.lineComment = bytes[cursor + 1] == 47
                state.blockComment = !state.lineComment
                state.blockStar = false
                let third = cursor + 2 < bytes.count ? bytes[cursor + 2] : 0
                state.documentation =
                    state.lineComment
                    ? third == 33 || third == 47 && !(cursor + 3 < bytes.count && bytes[cursor + 3] == 47)
                    : third == 33 || third == 42
                try emit(cursor, cursor + 2, kind: .comment, style: commentStyle)
                cursor += 2
            }
            else if try beginLiteral() {
                state.logicalStart = false
            }
            else if state.expectsHeader, byte == 60 {
                state.header = true
                state.escape = false
                state.escapeDigits = 0
                state.escapeRadix = nil
                state.expectsHeader = false
                literalStart = cursor
                try emit(cursor, cursor + 1, kind: .string, style: "header")
                cursor += 1
            }
            else if byte == 35, state.logicalStart {
                state.preprocessor = true
                state.directiveWord = true
                state.logicalStart = false
                try emit(cursor, cursor + 1, kind: .keyword, style: "preprocessor")
                cursor += 1
            }
            else if byte >= 48 && byte <= 57
                || byte == 46 && cursor + 1 < bytes.count && bytes[cursor + 1] >= 48
                    && bytes[cursor + 1] <= 57
            {
                state.logicalStart = false
                state.expectsHeader = false
                try number()
            }
            else if Self.wordStart(byte) || byte == 64 {
                state.logicalStart = false
                try word()
            }
            else {
                state.logicalStart = false
                state.expectsHeader = false
                let isOperator = "%^&*()-+=|{}[]:;<>,/?!.~".utf8.contains(byte)
                try emitCode(
                    cursor,
                    cursor + 1,
                    kind: isOperator ? .punctuation : .text,
                    style: isOperator ? "punctuation" : "text"
                )
                cursor += 1
            }
        }
    }

    /// 业务作用：普通物理换行结束当前预处理与行注释，跨行块注释和原始字面分别持有自身边界。
    /// 参数说明: 无。
    /// 返回：只重置当前逻辑行身份，不把候选文本或下一行当成同一宏体。
    mutating func endLogicalLine() {
        state.logicalStart = true
        state.preprocessor = false
        state.directiveWord = false
        state.expectsHeader = false
        state.lineComment = false
        state.blockStar = false
        state.continuedWord = false
        state.splicedWord = false
        state.continuedNumber = false
        state.numberUserLiteral = false
        state.directivePrefix = ""
    }

    /// 业务作用：识别原始 CR、LF 与 CRLF，Unicode 段分隔字节不被冒充 C 源码换行。
    /// 参数说明:
    /// - offset: 当前行内字节位置。
    /// 返回：实际结束符宽度，没有结束符时为零。
    func newlineWidth(at offset: Int) -> Int {
        guard offset < bytes.count else {
            return 0
        }
        if bytes[offset] == 13 {
            return offset + 1 < bytes.count && bytes[offset + 1] == 10 ? 2 : 1
        }
        return bytes[offset] == 10 ? 1 : 0
    }

    /// 业务作用：反斜线紧接物理结束符时保留当前逻辑上下文，注释和字符串续行采用同一规则。
    /// 参数说明:
    /// - offset: 当前行内起点。
    /// 返回：完整续行序列宽度，其它反斜线为零。
    func spliceWidth(at offset: Int) -> Int {
        guard bytes[offset] == 92 else {
            return 0
        }
        let ending = newlineWidth(at: offset + 1)
        return ending == 0 ? 0 : ending + 1
    }
}
