import Foundation
import NateCore

struct LatexLexing {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let styles: [String: LanguageTokenStyle]
    var state: LatexLexicalState
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var classes: [UInt8]

    /// 业务作用：LaTeX 的数学、标签、注释与逐字状态只在同一来源修订中连续传播。
    /// 参数说明:
    /// - text: 当前完整物理行，包含真实结束符。
    /// - base: 当前原文 UTF-8 起点。
    /// - snapshot: 用于完整行证明及有限前瞻的固定正文，缺省时只使用提供的连续字节。
    /// - styles: 当前语言资源的完整固定样式。
    /// - deadline: 所属语法任务的共同截止。
    /// - state: 前一完整范围的独立检查点，失败只设置诊断。
    /// 返回：完整标量边界上的有界样式；来源、状态、取消或容量不足时不发布部分检查点。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        styles: [String: LanguageTokenStyle]?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            let budget = ANSILexingBudget(deadline: deadline, maximumSteps: 8_388_608)
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.latex.nextOffset == nil || state.latex.nextOffset == base,
                let styles, styles.count <= 256,
                (0...12).allSatisfy({
                    styles[String($0)] != nil
                })
            else {
                throw NateError.message("LaTeX 高亮缺少完整样式，或范围与检查点不一致。")
            }
            let range = ByteRange(base, base + text.utf8.count)
            if let documentID = state.latex.documentID {
                // 数学和逐字模式必须持有当前正文的权威，旧修订或丢失来源的状态不能继续解释新文字。
                guard let snapshot, snapshot.id == documentID, snapshot.revision == state.latex.revision
                else {
                    throw NateError.message("LaTeX 检查点不属于当前文档修订。")
                }
            }
            if let snapshot {
                let tree = snapshot.text
                // 可选参数与环境标签依赖后续原文，分段不能凭相邻外观猜测完整边界。
                guard range.upper <= tree.byteCount,
                    tree.isBoundary(range.lower), tree.isBoundary(range.upper),
                    (range.lower == 0 || tree.byte(at: range.lower - 1) == 10
                        || tree.byte(at: range.lower - 1) == 13 && tree.byte(at: range.lower) != 10),
                    (range.upper == tree.byteCount || tree.byte(at: range.upper - 1) == 10
                        || tree.byte(at: range.upper - 1) == 13 && tree.byte(at: range.upper) != 10),
                    tree.bytes(in: range).elementsEqual(text.utf8)
                else {
                    throw NateError.message("LaTeX 高亮来源不是固定正文中的完整物理行。")
                }
            }
            var scanner = LatexLexing(
                bytes: Array(text.utf8),
                base: base,
                snapshot: snapshot,
                styles: styles,
                state: state.latex,
                budget: budget,
                classes: Array(repeating: UInt8(state.latex.style), count: text.utf8.count)
            )
            try scanner.scan()
            let tokens = try scanner.tokens()
            scanner.state.nextOffset = range.upper
            scanner.state.tail =
                scanner.bytes.count >= 32
                ? Array(scanner.bytes.suffix(32)) : Array((scanner.state.tail + scanner.bytes).suffix(32))
            if let snapshot {
                scanner.state.documentID = snapshot.id
                scanner.state.revision = snapshot.revision
            }
            // 呈现边界与末次取消复验先于状态发布，错误不能留下半个数学、逐字或可选参数上下文。
            try scanner.budget.check()
            state.latex = scanner.state
            return tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：逐字节解释 LaTeX 状态，各专用范围持有自己的关闭规则，不运行任何命令。
    /// 参数说明: 无。
    /// 返回：完整推进当前源范围，资源失败向入口抛错以舍弃全部临时分类。
    mutating func scan() throws {
        if let carried = state.carriedStyle, !bytes.isEmpty {
            // 单字符逐字分隔符可位于前一结束符之后，已确认的首字节身份先于新行状态解释。
            try paint(through: 0, style: carried)
            cursor = 1
            state.carriedStyle = nil
        }
        while cursor < bytes.count {
            try budget.consume()
            switch state.style {
            case 0, 3, 6:
                try ordinary()
            case 1:
                try command()
            case 2, 5:
                try tag()
            case 11:
                if byte(cursor) == 93 {
                    try paint(through: cursor, style: 11)
                    reset()
                }
            case 4:
                if byte(cursor) == 10 || byte(cursor) == 13 {
                    try paint(through: cursor - 1, style: 4)
                    reset()
                }
            case 7, 8:
                try literal()
            default:
                reset()
            }
            cursor += 1
        }
        try paint(through: bytes.count - 1, style: state.style)
    }

    /// 业务作用：暂存字节类别只推进已经确认的完整前缀，最终发布时再投影到 Unicode 标量边界。
    /// 参数说明:
    /// - end: 当前类别覆盖的最后原字节。
    /// - style: 当前确定的资源编号。
    /// 返回：当前未封存范围全部分类，源范围之外的哨兵不进入呈现。
    mutating func paint(through end: Int, style: Int) throws {
        let upper = min(bytes.count, max(segment, end + 1))
        while segment < upper {
            try budget.consume()
            classes[segment] = UInt8(style)
            segment += 1
        }
    }

    /// 业务作用：临时命令、注释或标签完成后恢复其外部数学模式，不把数学文字转成普通正文。
    /// 参数说明: 无。
    /// 返回：当前样式回到内联数学、块数学或中性正文。
    mutating func reset() {
        state.style = state.mode == 1 ? 3 : (state.mode == 2 ? 6 : 0)
    }

    /// 业务作用：原字节分类以每个完整标量的首字节身份发布，UTF-8 续字节不能产生半个字形范围。
    /// 参数说明: 无。
    /// 返回：至多 65536 个连续资源词元，容量不足时拒绝整行及检查点。
    mutating func tokens() throws -> [SyntaxToken] {
        var output: [SyntaxToken] = []
        let kinds: [SyntaxKind] = [
            .text, .keyword, .tag, .string, .comment, .tag, .string,
            .comment, .string, .keyword, .punctuation, .string, .text,
        ]
        var start = 0
        while start < bytes.count {
            try budget.consume()
            let style = classes[start]
            var end = start
            repeat {
                try budget.consume()
                let byte = bytes[end]
                end += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
            } while end < bytes.count && classes[end] == style
            guard output.count < 65_536, let attributes = styles[String(style)] else {
                throw NateError.message("LaTeX 高亮超过词元容量或缺少当前样式。")
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(base + start, base + end),
                    kind: kinds[Int(style)],
                    foreground: attributes.foreground,
                    background: attributes.background,
                    fontStyle: attributes.fontStyle,
                    lexicalStyle: "latex:" + String(style)
                )
            )
            start = end
        }
        return output
    }
}
