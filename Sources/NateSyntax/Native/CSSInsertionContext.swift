import Foundation
import NateCore

extension CSSLexing {
    /// 业务作用：CSS 结构输入只重放实际光标前缀，后继注释或引号不能冒充已输入的定界符。
    /// 参数说明:
    /// - source: 当前完整逻辑行原字节。
    /// - offset: 实际插入边界相对本行的位置。
    /// - base: 本行在固定正文中的原字节起点。
    /// - initial: 当前行之前的同源状态。
    /// - scanner: 绑定全文、规则和截止的 CSS 扫描器。
    /// 返回：完整确认的实际前缀状态；范围、来源或预算不足时拒绝本次准备。
    static func prefixState(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> CSSLexicalState {
        guard offset >= 0, offset <= source.count, let rules = scanner.cssRules else {
            throw NateError.invalidRange
        }
        var validated = initial
        _ = scanner.highlight(
            String(decoding: source[..<offset], as: UTF8.self),
            base: base,
            state: &validated
        )
        guard validated.diagnostic == nil else {
            throw NateError.message(validated.diagnostic ?? "CSS 插入点缺少完整来源。")
        }
        let cache = initial.cssCache.range != nil ? initial.cssCache : validated.cssCache
        var origin = base, before = initial.css
        if let range = cache.range, let predecessor = cache.initial {
            origin = range.lower
            before = predecessor
        }
        let prefix: [UInt8]
        if origin < base {
            guard let snapshot = scanner.snapshot else {
                throw NateError.message("CSS 插入点缺少完整物理前缀。")
            }
            prefix = snapshot.text.bytes(in: ByteRange(origin, base + offset))
        }
        else {
            prefix = Array(source[..<offset])
        }
        var replay = CSSScanner(
            bytes: prefix,
            base: origin,
            wantedUpper: base + offset,
            snapshot: scanner.snapshot,
            trueEOF: false,
            limitUpper: origin + prefix.count,
            rules: rules,
            prefixOnly: true,
            budget: ANSILexingBudget(deadline: scanner.deadline, maximumSteps: 33_554_432),
            state: before
        )
        return try replay.scan().state
    }

    /// 业务作用：CSS 只在实际非注释、非属性内容及非引号字面的前缀准备结构输入。
    /// 参数说明:
    /// - state: 已完整确认的实际光标前缀状态。
    /// 返回：注释、属性内容与单双引号字面为假，其它原生类别保持代码输入资格。
    static func isCode(_ state: CSSLexicalState) -> Bool {
        ![9, 13, 14, 16].contains(state.mode)
    }
}
