import Foundation
import NateCore

extension CompletionEngine {
    public static let maximumSignatureContextBytes = 65_536

    /// 业务作用：从有界调用上下文识别当前函数与参数，嵌套容器中的逗号不推进外层参数。
    /// 参数说明:
    /// - snapshot: 当前任务快照。
    /// - caret: 已验证的光标字节位置。
    /// - definition: 当前语言的函数与参数资源。
    /// - language: 获取原文中的不透明范围时采用的当前实际语言。
    /// - checkpoint: 同一正文和语言的已验证行首状态，缺少时从文档首行传播。
    /// 返回：最近一层有资源定义的实际开端字节及全部重载；没有适用规则时为空。
    public static func signature(
        snapshot: DocumentSnapshot,
        caret: Int,
        definition: CompletionDefinition,
        language: LanguageDefinition? = nil,
        checkpoint: (line: Int, state: LexicalState)? = nil
    ) throws -> SignatureHint? {
        guard snapshot.text.isBoundary(caret), let opening = definition.startFunction.first,
            let closing = definition.stopFunction.first, let separator = definition.parameterSeparator.first,
            definition.entries.contains(where: { !$0.overloads.isEmpty })
        else {
            return nil
        }
        var start = max(0, caret - maximumSignatureContextBytes)
        while !snapshot.text.isBoundary(start) {
            start += 1
        }
        let range = ByteRange(start, caret)
        let source = snapshot.text.text(in: range)
        guard source.contains(opening) else {
            return nil
        }
        let characters =
            if let language {
                try signatureCharacters(
                    source,
                    in: snapshot,
                    range: range,
                    language: language,
                    checkpoint: checkpoint
                )
            }
            else {
                Array(source)
            }
        var stack: [(close: Character, name: String?, argument: Int, openingByte: Int)] = []
        var position = start
        var quote: Character?
        var escaped = false
        for (index, character) in characters.enumerated() {
            let byte = position
            position += character.utf8.count
            if index % 4096 == 0 {
                try Task.checkCancellation()
            }
            if language == nil, let current = quote {
                if escaped {
                    escaped = false
                }
                else if character == "\\" {
                    escaped = true
                }
                else if character == current {
                    quote = nil
                }
                continue
            }
            if language == nil, character == "\"" || character == "'" || character == "`" {
                quote = character
                continue
            }
            if character == opening || character == "[" || character == "{" {
                var name: String?
                if character == opening {
                    var end = index
                    while end > 0, characters[end - 1].isWhitespace {
                        end -= 1
                    }
                    var first = end
                    while first > 0,
                        characters[first - 1].unicodeScalars.allSatisfy({
                            isWord($0, additional: definition.additionalWordCharacters + "!:.")
                        })
                    {
                        first -= 1
                    }
                    // 视窗起点切到一个名称中间时，后半段不能冒充目录中另一项函数。
                    if first < end, first > 0 || start == 0 {
                        name = String(characters[first..<end])
                    }
                }
                stack.append((character == opening ? closing : character == "[" ? "]" : "}", name, 0, byte))
                if stack.count > 256 {
                    throw NateError.message("参数提示上下文超过 256 层。")
                }
            }
            else if character == stack.last?.close {
                stack.removeLast()
            }
            else if character == separator && !stack.isEmpty {
                stack[stack.count - 1].argument += 1
            }
        }
        guard quote == nil else {
            return nil
        }
        for frame in stack.reversed() {
            guard let name = frame.name,
                let entry = definition.entries.first(where: {
                    definition.ignoresCase
                        ? $0.name.caseInsensitiveCompare(name) == .orderedSame : $0.name == name
                }), !entry.overloads.isEmpty
            else {
                continue
            }
            return SignatureHint(
                name: entry.name,
                argument: frame.argument,
                openingByte: frame.openingByte,
                overloads: entry.overloads
            )
        }
        return nil
    }

    /// 业务作用：复用当前语言已确认的词法作用域，字符串、注释和预处理体中的标点不参与参数计数。
    /// 参数说明:
    /// - source: 当前有界上下文的完整原文。
    /// - snapshot: 当前请求固定的原始正文。
    /// - range: 从完整标量到光标的有限调用上下文。
    /// - language: 当前编辑器采用的内置语言规则。
    /// - checkpoint: 属于同一快照的已验证起始状态。
    /// 返回：只供参数分析的字符序列，完整词法超限时拒绝提示且保留原正文。
    private static func signatureCharacters(
        _ source: String,
        in snapshot: DocumentSnapshot,
        range: ByteRange,
        language: LanguageDefinition,
        checkpoint: (line: Int, state: LexicalState)?
    ) throws -> [Character] {
        let tree = snapshot.text
        let first = tree.lineNumber(at: range.lower)
        let last = tree.lineNumber(at: range.upper)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        let analysis = try SyntaxAnalysis.analyze(
            snapshot: snapshot,
            language: language,
            udl: nil,
            visible: first..<(last + 1),
            startLine: checkpoint?.line ?? 0,
            initial: checkpoint?.state,
            deadline: deadline
        )
        let opaque = analysis.tokens.values.flatMap { $0 }.filter(\.isStructureOpaque).sorted {
            $0.range.lower < $1.range.lower
        }
        var bytes = Array(source.utf8)
        var consumed = range.lower
        for token in opaque {
            try Task.checkCancellation()
            let lower = max(token.range.lower, consumed)
            let upper = min(token.range.upper, range.upper)
            guard lower < upper else {
                continue
            }
            // 注释等同分词空白，字符串及指令只阻断跨范围取函数名；两者内部标点均不计入调用。
            guard tree.isBoundary(lower), tree.isBoundary(upper), ContinuousClock.now < deadline else {
                throw NateError.message("参数提示缺少完整的调用上下文或已超过词法预算。")
            }
            for index in (lower - range.lower)..<(upper - range.lower) {
                bytes[index] = token.kind == .comment ? 32 : 0
            }
            consumed = upper
        }
        return Array(String(decoding: bytes, as: UTF8.self))
    }
}
