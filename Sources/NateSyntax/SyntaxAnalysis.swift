import Foundation
import NateCore

public enum LexicalState: Sendable {
    case native(SyntaxState)
    case user(UDLState)
}

public struct SyntaxAnalysis: Sendable {
    public let tokens: [Int: [SyntaxToken]]
    public let checkpoints: [Int: LexicalState]

    /// 业务作用：从安全行边界传播词法状态，跨行修改影响后续呈现。
    /// 参数说明:
    /// - snapshot: 已提交正文。
    /// - language: 当前语言资源。
    /// - udl: 独立 UDL 定义，为空时使用内置词法。
    /// - visible: 需要保留样式的逻辑行范围。
    /// - startLine: 可信行首检查点。
    /// - initial: 与该检查点匹配的词法状态。
    /// - deadline: 所属操作的共同截止，为空时最多五秒，调用方不能借新分析延长既有期限。
    /// 返回：有界可见行样式及稀疏行首状态；行号无效、取消或超量时不发布部分样式。
    public static func analyze(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        udl: UDLDefinition?,
        visible: Range<Int>,
        startLine: Int,
        initial: LexicalState?,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> SyntaxAnalysis {
        // 行号只来自正文的 CR/LF 索引；失配检查点不能构造倒置范围或借越界跳过状态传播。
        guard visible.lowerBound >= 0, startLine >= 0,
            startLine <= min(snapshot.text.lineCount, visible.upperBound),
            startLine <= visible.lowerBound
        else {
            throw NateError.invalidRange
        }
        var native = SyntaxState()
        var user = UDLState()
        if case .native(let state) = initial {
            native = state
        }
        if case .user(let state) = initial {
            user = state
        }
        var checkpoints: [Int: LexicalState] = [:]
        var output: [Int: [SyntaxToken]] = [:]
        let taskDeadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        try Task.checkCancellation()
        guard ContinuousClock.now < taskDeadline else {
            throw NateError.message("当前高亮任务已超过所属操作截止，未准备部分样式。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: taskDeadline)
        var consumed = 0
        var retainedTokens = 0
        for line in startLine..<min(snapshot.text.lineCount, visible.upperBound) {
            try Task.checkCancellation()
            guard ContinuousClock.now < taskDeadline else {
                throw NateError.message("当前高亮任务超出资源预算，正文仍可编辑；请在较近位置继续查看。")
            }
            if line % 128 == 0 {
                checkpoints[line] = udl == nil ? .native(native) : .user(user)
                if checkpoints.count > 4096 {
                    checkpoints.removeValue(forKey: line - 4095 * 128)
                }
            }
            let range = snapshot.text.lineRange(line)
            // 单次范围在复制前纳入共同容量，最后一行也不能越过总量后再发布样式。
            guard range.count <= 1_048_576, consumed <= 64 * 1024 * 1024 - range.count else {
                throw NateError.message("当前高亮暂停：单行超过 1 MiB 或总量超过 64 MiB，无法确认后续词法状态。")
            }
            consumed += range.count
            let text = snapshot.text.text(in: range)
            let tokens =
                udl.map {
                    UDLLexer.highlight(
                        text,
                        base: range.lower,
                        definition: $0,
                        state: &user,
                        source: snapshot,
                        deadline: taskDeadline
                    )
                } ?? scanner.highlight(text, base: range.lower, state: &native)
            if let diagnostic = native.diagnostic ?? user.diagnostic {
                throw NateError.message(diagnostic)
            }
            if visible.contains(line) {
                guard tokens.count <= 262_144 - retainedTokens else {
                    throw NateError.message("当前高亮暂停：视口词法片段超过 262144 个。")
                }
                retainedTokens += tokens.count
                output[line] = tokens
            }
        }
        try Task.checkCancellation()
        // 最后一行也须在共同期限内完成，过期样式不能借循环已经结束而取得发布权。
        guard ContinuousClock.now < taskDeadline else {
            throw NateError.message("完整高亮已超过所属操作截止，未发布部分样式。")
        }
        return SyntaxAnalysis(
            tokens: output,
            checkpoints: checkpoints
        )
    }
}
