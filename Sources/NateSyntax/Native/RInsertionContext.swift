import Foundation
import NateCore

extension RLexing {
    /// 业务作用：R 结构输入只沿插入点前缀判断，后继闭合不能提前解除字符串或注释保护。
    /// 参数说明:
    /// - source: 当前逻辑行的实际原字节。
    /// - offset: 插入点相对本行的原字节边界。
    /// - base: 当前逻辑行的原字节起点。
    /// - initial: 该行开始前的同源状态。
    /// - scanner: 固定正文及完整资源的扫描器。
    /// 返回：实际代码区为真，字符串、注释及分隔运算符中为假；来源或预算不足时拒绝本次结构输入。
    static func isCode(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> Bool {
        guard offset >= 0, offset <= source.count, let rules = scanner.rRules else {
            throw NateError.invalidRange
        }
        var validated = initial
        _ = scanner.highlight(
            String(decoding: source[..<offset], as: UTF8.self),
            base: base,
            state: &validated
        )
        guard validated.diagnostic == nil else {
            throw NateError.message(validated.diagnostic ?? "R 插入点缺少完整词法来源。")
        }
        var origin = base
        var continuation = initial.r.continuation
        let physical = initial.r.cachedRange != nil ? initial.r : validated.r
        if let range = physical.cachedRange, let before = physical.cachedInitialContinuation {
            origin = range.lower
            continuation = before
        }
        let prefix: [UInt8]
        if origin < base {
            guard let snapshot = scanner.snapshot else {
                throw NateError.message("R 插入点缺少完整物理前缀。")
            }
            prefix = snapshot.text.bytes(in: ByteRange(origin, base + offset))
        }
        else {
            prefix = Array(source[..<offset])
        }
        var current = RLexicalState()
        current.continuation = continuation
        // 显示前瞻只证明来源；重放实际已输入前缀时不把文件末尾哨兵当成已输入的行尾。
        var bounded = RLexing(
            bytes: prefix,
            rules: rules,
            documentEnd: false,
            state: current,
            budget: ANSILexingBudget(deadline: scanner.deadline, maximumSteps: 16_777_216),
            classes: Array(repeating: 0, count: prefix.count)
        )
        try bounded.scan()
        try bounded.budget.check()
        return ![1, 6, 7, 10, 11, 12, 13, 14, 15].contains(bounded.state.mode)
    }
}
