import Foundation

enum UDLQuotedWords {
    /// 业务作用：保留 UDL 引号短语的两种空白职责，转义引号与反斜杠作为字面内容而不是分词边界。
    /// 参数说明:
    /// - text: 当前整组关键字、整词运算符或整词折叠声明。
    /// 返回：原顺序候选；双引号空白用跨行标记，单引号空白用同行标记，双括号字面短语保持原行为。
    static func parse(_ text: String) -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var word: [Character] = []
        var quote: Character?
        var whitespace: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quote == nil, word.isEmpty, character == "(", index + 1 < characters.count,
                characters[index + 1] == "("
            {
                let start = index + 2
                index = start
                while index + 1 < characters.count,
                    !(characters[index] == ")" && characters[index + 1] == ")")
                {
                    index += 1
                }
                words.append(String(characters[start..<index]))
                index = min(characters.count, index + 2)
                continue
            }
            if character == "\\", index + 1 < characters.count,
                ["\\", "\"", "'"].contains(characters[index + 1])
            {
                if let whitespace, !word.isEmpty {
                    word.append(whitespace)
                }
                whitespace = nil
                word.append(characters[index + 1])
                index += 2
                continue
            }
            if (character == "\"" || character == "'"), quote == nil || quote == character {
                if quote == character {
                    quote = nil
                    whitespace = nil
                }
                else {
                    quote = character
                }
                index += 1
                continue
            }
            if character.isWhitespace {
                if let quote {
                    if !word.isEmpty {
                        whitespace = quote == "\"" ? "\u{B}" : "\u{8}"
                    }
                }
                else if !word.isEmpty {
                    words.append(String(word))
                    word.removeAll(keepingCapacity: true)
                    whitespace = nil
                }
                index += 1
                continue
            }
            if let whitespace, !word.isEmpty {
                word.append(whitespace)
            }
            whitespace = nil
            word.append(character)
            index += 1
        }
        if !word.isEmpty {
            words.append(String(word))
        }
        return words
    }
}
