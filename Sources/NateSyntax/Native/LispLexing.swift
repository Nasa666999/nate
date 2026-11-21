import Foundation
import NateCore

struct LispLexing {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let language: String
    let styles: [String: LanguageTokenStyle]
    let keywords: Set<String>
    let secondary: Set<String>
    var state: LispLexicalState
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var classes: [UInt8]

    /// 业务作用：Lisp 与 Scheme 共用原字节状态机，各自保留独立关键字资源和跨行字面状态。
    /// 参数说明:
    /// - text: 当前完整物理范围，保留真实结束符。
    /// - base: 当前范围原字节起点。
    /// - snapshot: 固定正文，用于来源及真实末尾证明。
    /// - language: 当前 Lisp 或 Scheme 身份。
    /// - styles: 完整样式及未完成读取宏的默认呈现。
    /// - keywords: 当前语言函数和特殊操作符词表。
    /// - secondary: 当前语言第二关键字词表。
    /// - deadline: 所属语法任务的共同截止。
    /// - state: 连续范围的检查点，失败只设置诊断。
    /// 返回：完整标量范围上的有界样式，失败不发布部分词元或状态。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        language: String,
        styles: [String: LanguageTokenStyle]?,
        keywords: Set<String>,
        secondary: Set<String>,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            let budget = ANSILexingBudget(deadline: deadline, maximumSteps: 8_388_608)
            try budget.check()
            let required = [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 29, 30, 31]
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.lisp.nextOffset == nil || state.lisp.nextOffset == base,
                let styles, styles.count <= 256,
                required.allSatisfy({
                    styles[String($0)] != nil
                })
            else {
                throw NateError.message("Lisp 高亮缺少完整样式，或范围与检查点不一致。")
            }
            let range = ByteRange(base, base + text.utf8.count)
            if let snapshot {
                let tree = snapshot.text
                // 完整物理边界使字符串和块注释检查点可复用，不能将 CRLF 的中间位置当成独立行。
                guard range.upper <= tree.byteCount,
                    tree.isBoundary(range.lower), tree.isBoundary(range.upper),
                    (range.lower == 0 || tree.byte(at: range.lower - 1) == 10
                        || tree.byte(at: range.lower - 1) == 13 && tree.byte(at: range.lower) != 10),
                    (range.upper == tree.byteCount || tree.byte(at: range.upper - 1) == 10
                        || tree.byte(at: range.upper - 1) == 13 && tree.byte(at: range.upper) != 10),
                    tree.bytes(in: range).elementsEqual(text.utf8)
                else {
                    throw NateError.message("Lisp 高亮来源不是固定正文中的完整物理范围。")
                }
            }
            var scanner = LispLexing(
                bytes: Array(text.utf8),
                base: base,
                snapshot: snapshot,
                language: language,
                styles: styles,
                keywords: keywords,
                secondary: secondary,
                state: state.lisp,
                budget: budget,
                classes: Array(repeating: UInt8(state.lisp.style), count: text.utf8.count)
            )
            try scanner.scan()
            let tokens = try scanner.tokens()
            scanner.state.nextOffset = range.upper
            // 最后一次取消复验先于检查点发布，容量或截止失败不能留下半个读取宏。
            try scanner.budget.check()
            state.lisp = scanner.state
            return tokens
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：暂存确定的原字节类别，逻辑片段起点独立于相邻样式是否相同。
    /// 参数说明:
    /// - end: 已确定类别的最后字节。
    /// - style: 当前样式身份。
    /// 返回：封存当前前缀，越界哨兵不进入原文范围。
    mutating func paint(_ end: Int, _ style: Int) throws {
        let upper = min(bytes.count, max(segment, end + 1))
        while segment < upper {
            try budget.consume()
            classes[segment] = UInt8(style)
            segment += 1
        }
    }

    /// 业务作用：字节分类按完整 Unicode 标量呈现，读取宏中间状态仍保留默认资源身份。
    /// 参数说明: 无。
    /// 返回：最多 65536 个完整词元，缺少样式或超量时拒绝整行。
    mutating func tokens() throws -> [SyntaxToken] {
        let kinds: [Int: SyntaxKind] = [
            0: .text,
            1: .comment,
            2: .number,
            3: .keyword,
            4: .keyword,
            5: .tag,
            6: .string,
            9: .text,
            10: .punctuation,
            11: .tag,
            12: .comment,
            29: .text,
            30: .text,
            31: .text,
        ]
        var output: [SyntaxToken] = []
        var start = 0
        while start < bytes.count {
            try budget.consume()
            let style = Int(classes[start])
            var end = start
            repeat {
                try budget.consume()
                let current = bytes[end]
                end += current < 128 ? 1 : (current < 224 ? 2 : (current < 240 ? 3 : 4))
            } while end < bytes.count && Int(classes[end]) == style
            guard output.count < 65_536, let attributes = styles[String(style)], let kind = kinds[style]
            else {
                throw NateError.message("Lisp 高亮超过词元容量或缺少当前样式。")
            }
            output.append(
                SyntaxToken(
                    range: ByteRange(base + start, base + end),
                    kind: kind,
                    foreground: attributes.foreground,
                    background: attributes.background,
                    fontStyle: attributes.fontStyle,
                    lexicalStyle: language + ":" + String(style)
                )
            )
            start = end
        }
        return output
    }
}
