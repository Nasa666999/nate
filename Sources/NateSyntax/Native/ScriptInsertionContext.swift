import Foundation
import NateCore

extension ScriptLexing {
    /// 业务作用：脚本结构输入只读取已经输入的物理前缀，后继引号和模板闭合不能提前开放代码区。
    /// 参数说明:
    /// - source: 当前逻辑行的完整原字节。
    /// - offset: 实际插入点在当前行的原字节边界。
    /// - base: 当前逻辑行的原字节起点。
    /// - initial: 本行开始前的同源状态。
    /// - scanner: 与当前完整资源和正文绑定的扫描器。
    /// 返回：实际代码区为真，字面、注释及预处理体为假；来源不足时拒绝本次结构动作。
    static func isCode(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> Bool {
        let state = try prefixState(
            source: source,
            offset: offset,
            base: base,
            initial: initial,
            scanner: scanner
        )
        return isCode(state)
    }

    /// 业务作用：换行与字符缩进共用实际光标前缀状态，文档命令片段不能丢失所属行注释身份。
    /// 参数说明:
    /// - source: 当前逻辑行的完整原字节。
    /// - offset: 需要确认的实际插入边界。
    /// - base: 当前逻辑行的原字节起点。
    /// - initial: 当前行之前的同源词法证据。
    /// - scanner: 绑定完整资源、正文与共同截止的扫描器。
    /// 返回：已完整确认的前缀状态；失配、超量或取消时抛错，不发布部分状态。
    static func prefixState(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner
    ) throws -> CLexicalState {
        guard offset >= 0, offset <= source.count, let rules = scanner.scriptRules else {
            throw NateError.invalidRange
        }
        var validated = initial
        _ = scanner.highlight(
            String(decoding: source[..<offset], as: UTF8.self),
            base: base,
            state: &validated
        )
        guard validated.diagnostic == nil else {
            throw NateError.message(validated.diagnostic ?? "脚本插入点缺少完整来源。")
        }
        var origin = base
        var before = initial.c
        let cache = initial.scriptCache.range != nil ? initial.scriptCache : validated.scriptCache
        if let range = cache.range, let predecessor = cache.initial {
            origin = range.lower
            before = predecessor
        }
        let prefix: String
        if origin < base {
            guard let snapshot = scanner.snapshot else {
                throw NateError.message("脚本插入点缺少完整物理前缀。")
            }
            prefix = snapshot.text.text(in: ByteRange(origin, base + offset))
        }
        else {
            prefix = String(decoding: source[..<offset], as: UTF8.self)
        }
        var replay = SyntaxState()
        replay.c = before
        _ = CLexing.highlight(
            prefix,
            base: origin,
            language: scanner.language.id,
            keywords: [],
            secondaryKeywords: [],
            globalClasses: [],
            documentationKeywords: [],
            snapshot: scanner.snapshot,
            scriptRules: rules,
            deadline: scanner.deadline,
            state: &replay
        )
        guard replay.diagnostic == nil else {
            throw NateError.message(replay.diagnostic ?? "脚本插入点前缀未完整确认。")
        }
        return replay.c
    }

    /// 业务作用：只有完整前缀确认不属于字面、注释或预处理体时，结构标点才有缩进资格。
    /// 参数说明:
    /// - state: 已验证的实际插入点前缀状态。
    /// 返回：可以按代码结构处理时为真，其它上下文保留原缩进。
    static func isCode(_ state: CLexicalState) -> Bool {
        !state.blockComment && !state.lineComment && state.quote == nil
            && state.rawEnding.isEmpty && !state.verbatim && !state.regex
            && !state.preprocessor && !state.header
    }
}
