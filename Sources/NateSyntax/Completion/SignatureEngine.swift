import Foundation
import NateCore

extension CompletionEngine {
    /// 业务作用：从有界调用上下文识别当前函数与参数，嵌套容器中的逗号不推进外层参数。
    /// 参数说明:
    /// - snapshot: 当前任务快照。
    /// - caret: 已验证的光标字节位置。
    /// - definition: 当前语言的函数与参数资源。
    /// 返回：最近一层有资源定义的调用及全部重载；没有适用规则时为空。
    public static func signature(
        snapshot: DocumentSnapshot,
        caret: Int,
        definition: CompletionDefinition
    ) throws -> SignatureHint? {
        guard snapshot.text.isBoundary(caret), let opening = definition.startFunction.first,
            let closing = definition.stopFunction.first, let separator = definition.parameterSeparator.first
        else {
            return nil
        }
        var start = max(0, caret - 65_536)
        while !snapshot.text.isBoundary(start) {
            start += 1
        }
        let characters = Array(snapshot.text.text(in: ByteRange(start, caret)))
        var stack: [(close: Character, name: String?, argument: Int)] = []
        var quote: Character?
        var escaped = false
        for (index, character) in characters.enumerated() {
            if index % 4096 == 0 {
                try Task.checkCancellation()
            }
            if let current = quote {
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
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                continue
            }
            if character == opening || character == "[" || character == "{" {
                var name: String?
                if character == opening {
                    let prefix = characters[..<index].reversed().drop(while: \.isWhitespace)
                        .prefix {
                            $0.unicodeScalars.allSatisfy {
                                isWord($0, additional: definition.additionalWordCharacters + "!:.")
                            }
                        }
                    name = String(prefix.reversed())
                }
                stack.append((character == opening ? closing : character == "[" ? "]" : "}", name, 0))
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
            return SignatureHint(name: entry.name, argument: frame.argument, overloads: entry.overloads)
        }
        return nil
    }
}
