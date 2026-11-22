import Foundation
import NateCore

extension MSSQLLexing {
    /// 业务作用：结构输入读取真实光标前缀，后继引号或注释闭合不能提前授予代码资格。
    /// 参数说明:
    /// - source: 当前完整逻辑行的原字节。
    /// - offset: 实际插入边界相对当前行的位置。
    /// - base: 当前逻辑行在固定正文中的起点。
    /// - initial: 本行之前的同源词法状态。
    /// - scanner: 绑定当前完整正文、规则和截止的扫描器。
    /// 返回：完整确认的实际前缀状态；范围、来源或预算不足时拒绝本次输入准备。
    static func prefixState(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> MSSQLLexicalState {
        guard offset >= 0, offset <= source.count, let rules = scanner.mssqlRules else {
            throw NateError.invalidRange
        }
        var validated = initial
        _ = scanner.highlight(
            String(decoding: source[..<offset], as: UTF8.self),
            base: base,
            state: &validated
        )
        guard validated.diagnostic == nil else {
            throw NateError.message(validated.diagnostic ?? "T-SQL 插入点缺少完整来源。")
        }
        var origin = base
        var before = initial.mssql
        let cache = initial.mssqlCache.range != nil ? initial.mssqlCache : validated.mssqlCache
        if let range = cache.range, let predecessor = cache.initial {
            origin = range.lower
            before = predecessor
        }
        let prefix: [UInt8]
        if origin < base {
            guard let snapshot = scanner.snapshot else {
                throw NateError.message("T-SQL 插入点缺少完整物理前缀。")
            }
            prefix = snapshot.text.bytes(in: ByteRange(origin, base + offset))
        }
        else {
            prefix = Array(source[..<offset])
        }
        var replay = MSSQLScanner(
            bytes: prefix,
            base: origin,
            rules: rules,
            snapshot: scanner.snapshot,
            budget: ANSILexingBudget(deadline: scanner.deadline, maximumSteps: 16_777_216),
            state: before
        )
        try replay.scan()
        return replay.state
    }

    /// 业务作用：T-SQL 只在真实代码区按块关键字调整缩进，未完成名称仍属于代码前缀。
    /// 参数说明:
    /// - state: 已完整验证的光标前缀状态。
    /// 返回：代码、名称与变量区为真，注释、字符串及引用列名为假。
    static func isCode(_ state: MSSQLLexicalState) -> Bool {
        [0, 6, 7, 12, 15].contains(state.mode)
    }
}
