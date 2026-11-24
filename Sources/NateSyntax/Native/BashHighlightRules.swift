import Foundation

private struct BashHighlightIdentity: Encodable {
    let words: [String]
    let styles: [String: LanguageTokenStyle]
}

struct BashHighlightRules: Sendable {
    let identity: Data
    let words: Set<String>
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：固定 Bash 命令词表与十四种原生样式，来源改变后旧词法传播失去资格。
    /// 参数说明:
    /// - language: 当前明确的 Bash 语言资源。
    /// - deadline: 字段复验和编码共用的截止。
    /// 返回：完整 65536 词项及有限颜色字段可建立规则；缺失、取消或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        let source = language.keywordGroups?["instre1"] ?? language.keywords
        guard language.id == "bash", source.count <= 65_536, let styles = language.lexicalStyles,
            styles.count <= 256, (0...13).allSatisfy({ styles[String($0)] != nil })
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024
        for word in source {
            guard !word.isEmpty, word.utf8.count <= remaining,
                !word.utf8.contains(where: { $0 <= 32 }),
                !Task.isCancelled, ContinuousClock.now < deadline
            else {
                return nil
            }
            remaining -= word.utf8.count
        }
        for (key, style) in styles {
            guard key.utf8.count <= 3,
                [style.foreground, style.background].allSatisfy({ value in
                    value.map { $0.utf8.count <= 8 } ?? true
                }),
                !Task.isCancelled, ContinuousClock.now < deadline
            else {
                return nil
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // 先核对原字段再编码，巨型或非法来源不能占用整次扫描的展示额度。
        guard let data = try? encoder.encode(BashHighlightIdentity(words: source, styles: styles)),
            data.count <= 8 * 1024 * 1024, !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        words = Set(source)
        self.styles = styles
    }
}
