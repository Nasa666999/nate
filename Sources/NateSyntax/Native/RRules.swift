import Foundation

private struct RRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct RRules: Sendable {
    static let groupNames = ["instre1", "instre2", "type1"]
    let identity: Data
    let groups: [Set<Data>]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：R 三组词表按原顺序独立保存，先限制有效资源再建立原字节规则身份。
    /// 参数说明:
    /// - language: 当前固定 R 定义。
    /// - deadline: 资源准备与词法共用的截止。
    /// 返回：最多 65536 个词条、4 MiB 原始字段及 8 MiB 编码的完整规则，缺失或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard !Task.isCancelled, ContinuousClock.now < deadline,
            let groups = language.keywordGroups, let styles = language.lexicalStyles,
            styles.count <= 256,
            Self.groupNames.allSatisfy({
                groups[$0] != nil
            }),
            (0...15).allSatisfy({
                styles[String($0)] != nil
            })
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024
        var count = 0
        var used: [String: [String]] = [:]
        for name in Self.groupNames {
            let words = groups[name] ?? []
            guard words.count <= 65_536 - count else {
                return nil
            }
            count += words.count
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
            used[name] = words
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
        let source = RRuleIdentity(
            groups: used,
            styles: styles
        )
        guard let encoded = try? encoder.encode(source),
            encoded.count <= 8 * 1024 * 1024, !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = encoded
        self.groups = Self.groupNames.map {
            Set(
                (used[$0] ?? []).map {
                    Data($0.utf8)
                }
            )
        }
        self.styles = styles
    }
}
