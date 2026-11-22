import Foundation
import NateCore

enum StructuralInsertionContext {
    /// 业务作用：插入点沿完整前行状态重新读取本行前缀，行尾注释及未闭合字符串不能取得缩进修改权。
    /// 参数说明:
    /// - source: 当前物理行的完整原字节。
    /// - offset: 插入点相对本行的明确字节边界。
    /// - base: 本行在固定正文中的起点。
    /// - initial: 本行开始前已确认的词法状态。
    /// - scanner: 与完整来源及当前语言绑定的词法扫描器。
    /// - language: 当前内置语言的注释及字面规则。
    /// 返回：前缀完整扫描后确在代码区时为真，不透明区为假；词法证据不足时抛错。
    static func isCode(
        source: [UInt8],
        offset: Int,
        base: Int,
        initial: SyntaxState,
        scanner: SyntaxScanner,
        language: LanguageDefinition
    ) throws -> Bool {
        if language.id == "powershell" {
            return try PowerShellLexing.isCode(
                source: source,
                offset: offset,
                base: base,
                initial: initial,
                scanner: scanner
            )
        }
        if language.id == "rust" {
            return try RustLexing.isCode(
                source: source,
                offset: offset,
                base: base,
                initial: initial,
                scanner: scanner
            )
        }
        var state = initial
        let prefix = String(decoding: source[..<offset], as: UTF8.self)
        let tokens = scanner.highlight(prefix, base: base, state: &state)
        guard state.diagnostic == nil else {
            throw NateError.message(state.diagnostic ?? "结构字符的插入点缺少完整词法证据。")
        }
        guard state.blockEnd.isEmpty, !state.c.blockComment, !state.c.lineComment,
            state.c.quote == nil, state.c.rawEnding.isEmpty, !state.c.regex, !state.c.header,
            !state.c.preprocessor, !state.json.blockComment, !state.json.lineComment,
            state.json.quote == nil
        else {
            return false
        }
        // 原生词法状态已经包含闭合证据，基础词法则仍需确认行尾片段确实有完整终止符。
        guard let token = tokens.last, token.range.upper == base + offset,
            token.isStructureOpaque,
            !language.usesSharedCLexer, !["c", "cpp", "json", "json5"].contains(language.id)
        else {
            return true
        }
        let start = token.range.lower - base
        let bytes = source[start..<offset]
        if token.kind == .comment {
            let closing = Array(language.blockEnd.utf8)
            let opening = Array(language.blockStart.utf8)
            let continued = !initial.blockEnd.isEmpty && start == 0
            return !closing.isEmpty && bytes.suffix(closing.count).elementsEqual(closing)
                && (continued || !opening.isEmpty && bytes.starts(with: opening))
        }
        if token.kind == .string, bytes.count >= 2, let quote = bytes.first,
            [34, 39, 96].contains(quote), bytes.last == quote
        {
            var slash = offset - 2, count = 0
            while slash > start, source[slash] == 92 {
                count += 1
                slash -= 1
            }
            return count & 1 == 0
        }
        return false
    }
}
