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
    /// 返回：有界可见行样式及稀疏行首状态，取消不发布部分配置。
    public static func analyze(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        udl: UDLDefinition?,
        visible: Range<Int>,
        startLine: Int,
        initial: LexicalState?
    ) throws -> SyntaxAnalysis {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var consumed = 0
        for line in startLine..<min(snapshot.text.lineCount, visible.upperBound) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, consumed <= 64 * 1024 * 1024 else {
                throw NateError.message("当前高亮任务超出资源预算，正文仍可编辑；请在较近位置继续查看。")
            }
            if line % 128 == 0 {
                checkpoints[line] = udl == nil ? .native(native) : .user(user)
            }
            let range = snapshot.text.lineRange(line)
            consumed += range.count
            guard range.count <= 1_048_576 else {
                continue
            }
            let text = snapshot.text.text(in: range)
            let tokens =
                udl.map {
                    UDLLexer.highlight(text, base: range.lower, definition: $0, state: &user)
                } ?? SyntaxEngine.highlight(text, base: range.lower, language: language, state: &native)
            if visible.contains(line) {
                output[line] = tokens
            }
        }
        return SyntaxAnalysis(tokens: output, checkpoints: checkpoints)
    }
}
