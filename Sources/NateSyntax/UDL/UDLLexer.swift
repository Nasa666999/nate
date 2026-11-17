import Foundation
import NateCore

public struct UDLContext: Sendable, Equatable {
    var style: String
    var ends: [String]
    var escapes: [String]
    var lineOnly: Bool
}

public struct UDLState: Sendable, Equatable {
    var contexts: [UDLContext] = []

    /// 业务作用：建立独立 UDL 行首状态，供跨行分隔符和注释传播。
    /// 参数说明: 无。
    /// 返回：中性词法状态。
    public init() {}
}

public enum UDLLexer {
    /// 业务作用：按 UDL 字面规则与 nesting 权限执行，不将规则改写成通用正则。
    /// 参数说明:
    /// - text: 连续文本片段。
    /// - base: 文档内字节起点。
    /// - definition: 已校验完整 UDL。
    /// - state: 安全边界处的跨行状态。
    /// 返回：有顺序的样式范围，未闭合上下文传给后续片段。
    public static func highlight(_ text: String, base: Int, definition: UDLDefinition, state: inout UDLState)
        -> [SyntaxToken]
    {
        let bytes = Array(text.utf8)
        let comments = indexed(definition.lists["Comments"] ?? [])
        let delimiters = indexed(definition.lists["Delimiters"] ?? [])
        var tokens: [SyntaxToken] = []
        var i = 0
        while i < bytes.count {
            let start = i
            let context = state.contexts.last
            let nesting =
                context.flatMap {
                    definition.styles[$0.style]?.nesting
                } ?? UInt32.max
            if let context,
                let escape = longest(context.escapes, bytes: bytes, at: i, ignoreCase: definition.caseIgnored)
            {
                i = min(bytes.count, i + escape.utf8.count)
                if i < bytes.count {
                    i += 1
                    while i < bytes.count && bytes[i] & 0xC0 == 0x80 {
                        i += 1
                    }
                }
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: context.style,
                    definition: definition
                )
                continue
            }
            if let context,
                let end = longest(context.ends, bytes: bytes, at: i, ignoreCase: definition.caseIgnored)
            {
                i += end.utf8.count
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: context.style,
                    definition: definition
                )
                state.contexts.removeLast()
                continue
            }
            if let context, context.lineOnly, bytes[i] == 10 || bytes[i] == 13 {
                state.contexts.removeLast()
                continue
            }
            var entered = false
            if nesting & 0x100 != 0,
                let opener = longest(
                    comments[3] ?? [],
                    bytes: bytes,
                    at: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                state.contexts.append(
                    UDLContext(style: "COMMENTS", ends: comments[4] ?? [], escapes: [], lineOnly: false)
                )
                i += opener.utf8.count
                entered = true
            }
            else if nesting & 0x200 != 0,
                let opener = longest(
                    comments[0] ?? [],
                    bytes: bytes,
                    at: i,
                    ignoreCase: definition.caseIgnored
                )
            {
                state.contexts.append(
                    UDLContext(
                        style: "LINE COMMENTS",
                        ends: (comments[2] ?? []).filter {
                            $0 != "EOL" && $0 != "((EOL))"
                        },
                        escapes: comments[1] ?? [],
                        lineOnly: true
                    )
                )
                i += opener.utf8.count
                entered = true
            }
            else {
                for group in 0..<8 where nesting & (1 << group) != 0 {
                    if let opener = longest(
                        delimiters[group * 3] ?? [],
                        bytes: bytes,
                        at: i,
                        ignoreCase: definition.caseIgnored
                    ) {
                        let ends = delimiters[group * 3 + 2] ?? []
                        state.contexts.append(
                            UDLContext(
                                style: "DELIMITERS\(group + 1)",
                                ends: ends.filter {
                                    $0 != "EOL" && $0 != "((EOL))"
                                },
                                escapes: delimiters[group * 3 + 1] ?? [],
                                lineOnly: ends.contains("EOL") || ends.contains("((EOL))")
                            )
                        )
                        i += opener.utf8.count
                        entered = true
                        break
                    }
                }
            }
            if entered {
                if state.contexts.count > 128 {
                    state.contexts.removeFirst(state.contexts.count - 128)
                }
                emit(
                    &tokens,
                    start: base + start,
                    end: base + i,
                    style: state.contexts.last?.style ?? "DEFAULT",
                    definition: definition
                )
                continue
            }
            var matched = false
            for group in 1...8 where nesting & (1 << (group + 9)) != 0 {
                if i == 0 || !word(bytes[i - 1]),
                    let keyword = longest(
                        definition.lists["Keywords\(group)"] ?? [],
                        bytes: bytes,
                        at: i,
                        ignoreCase: definition.caseIgnored
                    )
                {
                    let end = i + keyword.utf8.count
                    if definition.prefix.contains(group) || end == bytes.count || !word(bytes[end]) {
                        i = end
                        emit(
                            &tokens,
                            start: base + start,
                            end: base + i,
                            style: "KEYWORDS\(group)",
                            definition: definition
                        )
                        matched = true
                        break
                    }
                }
            }
            if matched {
                continue
            }
            for group in 1...2 where nesting & (group == 1 ? 0x1000000 : 0x2000000) != 0 {
                if let op = longest(
                    definition.lists["Operators\(group)"] ?? [],
                    bytes: bytes,
                    at: i,
                    ignoreCase: definition.caseIgnored
                ) {
                    let end = i + op.utf8.count
                    if group == 1
                        || (i == 0 || !word(bytes[i - 1])) && (end == bytes.count || !word(bytes[end]))
                    {
                        i = end
                        emit(
                            &tokens,
                            start: base + start,
                            end: base + i,
                            style: "OPERATORS",
                            definition: definition
                        )
                        matched = true
                        break
                    }
                }
            }
            if matched {
                continue
            }
            if nesting & 0x4000000 != 0, (48...57).contains(bytes[i]), i == 0 || !word(bytes[i - 1]) {
                i += 1
                while i < bytes.count && ((48...57).contains(bytes[i]) || [46, 44, 95].contains(bytes[i])) {
                    i += 1
                }
                emit(&tokens, start: base + start, end: base + i, style: "NUMBERS", definition: definition)
                continue
            }
            i += 1
            while i < bytes.count && bytes[i] & 0xC0 == 0x80 {
                i += 1
            }
            emit(
                &tokens,
                start: base + start,
                end: base + i,
                style: context?.style ?? "DEFAULT",
                definition: definition
            )
        }
        state.contexts.removeAll {
            $0.lineOnly
        }
        return tokens
    }

    /// 业务作用：解析 UDL 的两位字段编号，编号用于规则组而不是字符码。
    /// 参数说明:
    /// - words: 原始有序规则。
    /// 返回：同一编号的多个候选标记。
    static func indexed(_ words: [String]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        for word in words {
            if let index = Int(word.prefix(2)), word.count > 2 {
                result[index, default: []].append(String(word.dropFirst(2)))
            }
        }
        return result
    }

    /// 业务作用：冲突的字面起止标记按最长匹配后原定义顺序确定。
    /// 参数说明:
    /// - patterns: 当前组允许的标记。
    /// - bytes: 输入原字节。
    /// - at: 当前字节位置。
    /// - ignoreCase: UDL 大小写选项。
    /// 返回：实际匹配的规则；不匹配为空。
    static func longest(_ patterns: [String], bytes: [UInt8], at: Int, ignoreCase: Bool) -> String? {
        patterns.enumerated().filter {
            _,
            pattern in
            let count = pattern.utf8.count
            guard count > 0, at + count <= bytes.count else {
                return false
            }
            let slice = bytes[at..<(at + count)]
            if !ignoreCase {
                return slice.elementsEqual(pattern.utf8)
            }
            return String(decoding: slice, as: UTF8.self).lowercased().utf8.elementsEqual(
                pattern.lowercased().utf8
            )
        }.max {
            a,
            b in
            a.element.utf8.count == b.element.utf8.count
                ? a.offset > b.offset : a.element.utf8.count < b.element.utf8.count
        }?.element
    }

    /// 业务作用：连续相同样式合并输出，避免按字节生成大量呈现对象。
    /// 参数说明:
    /// - tokens: 已生成范围。
    /// - start: 新片段起点。
    /// - end: 新片段结束。
    /// - style: 资源样式名。
    /// - definition: 完整 UDL。
    /// 返回：追加或合并呈现，不改正文。
    static func emit(
        _ tokens: inout [SyntaxToken],
        start: Int,
        end: Int,
        style: String,
        definition: UDLDefinition
    ) {
        let rule = definition.styles[style]
        let lexicalStyle = "udl:" + style
        let kind: SyntaxKind =
            style == "DEFAULT"
            ? .text
            : style.contains("COMMENT")
                ? .comment
                : style.contains("DELIMITER")
                    ? .string
                    : style == "NUMBERS" ? .number : style.hasPrefix("KEYWORDS") ? .keyword : .punctuation
        var start = start
        if let previous = tokens.last, previous.range.upper == start, previous.kind == kind,
            previous.lexicalStyle == lexicalStyle,
            previous.foreground == rule?.foreground, previous.fontStyle == rule?.fontStyle ?? 0
        {
            start = previous.range.lower
            tokens.removeLast()
        }
        tokens.append(
            SyntaxToken(
                range: ByteRange(start, end),
                kind: kind,
                foreground: rule?.foreground,
                fontStyle: rule?.fontStyle ?? 0,
                lexicalStyle: lexicalStyle
            )
        )
    }

    /// 业务作用：规则边界按标识符字节判断，不切开 UTF-8。
    /// 参数说明:
    /// - byte: 邻接字节。
    /// 返回：可构成词的字节。
    static func word(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
            || byte >= 128
    }
}
