import Foundation

private struct YAMLRuleIdentity: Encodable {
    let words: [String]
    let styles: [String: LanguageTokenStyle]
}

struct YAMLRules: Sendable {
    let identity: Data
    let words: Set<Data>
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：YAML 词表和样式先受完整容量限制，再建立独立原字节身份，不读取未使用的语言字段。
    /// 参数说明:
    /// - language: 当前固定 YAML 定义。
    /// - deadline: 资源准备与后续词法共用的截止。
    /// 返回：最多 4096 个词条、1 MiB 原始字段及 2 MiB 编码的完整资源，缺失或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard !Task.isCancelled, ContinuousClock.now < deadline,
            let words = language.keywordGroups?["instre1"], words.count <= 4096,
            let styles = language.lexicalStyles, styles.count <= 256,
            (0...9).allSatisfy({
                styles[String($0)] != nil
            })
        else {
            return nil
        }
        var remaining = 1_048_576
        for word in words {
            guard !word.isEmpty, word.utf8.count <= remaining,
                !word.utf8.contains(where: {
                    $0 <= 32
                }), !Task.isCancelled, ContinuousClock.now < deadline
            else {
                return nil
            }
            remaining -= word.utf8.count
        }
        for (name, style) in styles {
            guard name.utf8.count <= 32 else {
                return nil
            }
            for value in [name, style.foreground ?? "", style.background ?? ""] {
                guard value.utf8.count <= remaining else {
                    return nil
                }
                remaining -= value.utf8.count
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let source = YAMLRuleIdentity(
            words: words,
            styles: styles
        )
        guard let encoded = try? encoder.encode(source), encoded.count <= 2_097_152,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = encoded
        self.words = Set(
            words.map {
                Data($0.utf8)
            }
        )
        self.styles = styles
    }
}
