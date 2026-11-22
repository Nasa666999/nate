import Foundation
import NateCore

extension RustLexing {
    /// 业务作用：结构输入按明确插入点之前的 Rust 状态判断，完整物理行的后继闭合不能提前解除保护。
    /// 参数说明:
    /// - source: 当前逻辑行的实际原字节。
    /// - offset: 插入点相对本逻辑行的字节位置。
    /// - base: 本逻辑行的原字节起点。
    /// - initial: 该逻辑行开始前的同源检查点。
    /// - scanner: 当前固定正文和资源的扫描器。
    /// 返回：插入点在代码中为真，字面内容为假；来源或预算不足时拒绝本次结构输入。
    static func isCode(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> Bool {
        guard offset >= 0, offset <= source.count else {
            throw NateError.invalidRange
        }
        var validated = initial
        _ = scanner.highlight(
            String(decoding: source[..<offset], as: UTF8.self),
            base: base,
            state: &validated
        )
        guard validated.diagnostic == nil else {
            throw NateError.message(validated.diagnostic ?? "Rust 插入点缺少完整词法来源。")
        }
        var current = validated.rust
        if let range = current.cachedRange, let before = current.cachedInitial {
            guard let snapshot = scanner.snapshot, base + offset >= range.lower,
                base + offset <= range.upper
            else {
                throw NateError.message("Rust 插入点不属于已固定的物理范围。")
            }
            let prefix = snapshot.text.bytes(in: ByteRange(range.lower, base + offset))
            var state = RustLexicalState()
            state.style = before.style
            state.depth = before.depth
            state.hashes = before.hashes
            state.lineComment = before.lineComment
            // 后继字节只证明来源，不能把光标之后的闭合符算作已经输入；只重放实际前缀的字面状态。
            var bounded = RustLexing(
                bytes: prefix,
                base: range.lower,
                groups: [],
                state: state,
                budget: ANSILexingBudget(deadline: scanner.deadline, maximumSteps: 16_777_216),
                classes: Array(repeating: 0, count: prefix.count)
            )
            try bounded.scan()
            try bounded.budget.check()
            current = bounded.state
        }
        return current.depth == 0 && !current.lineComment
            && ![13, 14, 21, 22, 24, 25].contains(current.style)
    }
}
