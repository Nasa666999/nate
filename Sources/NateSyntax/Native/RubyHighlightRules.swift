import Foundation

private struct RubyHighlightIdentity: Encodable {
    let keywords: [String]
    let styles: [String: LanguageTokenStyle]
}

struct RubyHighlightRules: Sendable {
    let source: Data
    let keywords: Set<String>
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：绑定原始 Ruby 词表和样式；改变任一资源后必须重建传播证据。
    /// 参数说明:
    /// - language: 当前注册表解析出的 Ruby 定义。
    /// - deadline: 当前高亮流程共同截止。
    /// 返回：完整有界规则，资源缺失、取消或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        let words = language.keywordGroups?["instre1"] ?? language.keywords
        guard language.id == "ruby", words.count <= 65_536, let styles = language.lexicalStyles,
            styles.count == RubyHighlightStyle.allCases.count,
            RubyHighlightStyle.allCases.allSatisfy({ styles[String($0.rawValue)] != nil })
        else {
            return nil
        }
        var remaining = 4 * 1_048_576
        for word in words {
            guard !word.isEmpty, word.utf8.count <= remaining, !Task.isCancelled,
                ContinuousClock.now < deadline, !word.utf8.contains(where: { $0 <= 32 })
            else {
                return nil
            }
            remaining -= word.utf8.count
        }
        for style in styles.values {
            guard [style.foreground, style.background].allSatisfy({ $0.map { $0.utf8.count <= 8 } ?? true }),
                (0...7).contains(style.fontStyle)
            else {
                return nil
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(RubyHighlightIdentity(keywords: words, styles: styles)),
            data.count <= 8 * 1_048_576, !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        source = data
        keywords = Set(words)
        self.styles = styles
    }
}
