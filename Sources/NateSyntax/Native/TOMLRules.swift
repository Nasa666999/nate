import Foundation

private struct TOMLRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct TOMLRules: Sendable {
    static let groupNames = [
        "instre1"
    ]
    let identity: Data
    let groups: [Set<Data>]
    let prefixGroups: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：TOML 固定单组关键字与完整样式，字段在编码前通过容量和截止门禁。
    /// 参数说明:
    /// - language: 当前明确的 TOML 语言资源。
    /// - deadline: 所属词法操作的共同截止。
    /// 返回：最多 65536 项、4 MiB 原字段及 8 MiB 编码的完整规则；缺失或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        // 缺少任一类别时不能借用别处的样式，否则键名、表头和值会丢失自己的类别。
        guard language.id == "toml", let source = language.keywordGroups,
            let styles = language.lexicalStyles, styles.count <= 256,
            Self.groupNames.allSatisfy({
                source[$0] != nil
            }),
            (0...15).allSatisfy({
                styles[String($0)] != nil
            }),
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024, count = 0
        var used: [String: [String]] = [:]
        // 编码之前就限制原字段，外部词表不能先分配无限内容再依靠编码长度拒绝。
        for name in Self.groupNames {
            let words = source[name] ?? []
            guard words.count <= 65_536 - count else {
                return nil
            }
            count += words.count
            for word in words {
                guard !word.isEmpty, word.utf8.count <= remaining,
                    !word.utf8.contains(where: {
                        $0 <= 32
                    }),
                    !Task.isCancelled, ContinuousClock.now < deadline
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
        let value = TOMLRuleIdentity(
            groups: used,
            styles: styles
        )
        guard let data = try? encoder.encode(value),
            data.count <= 8 * 1024 * 1024, !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        groups = Self.groupNames.map { name in
            Set(
                (used[name] ?? []).map {
                    Data($0.utf8)
                }
            )
        }
        prefixGroups = groups.map { words in
            Set(
                words.filter {
                    $0.first == 94
                }.map {
                    Data($0.dropFirst())
                }
            )
        }
        prefixLengths = prefixGroups.map { words in
            Set(words.map(\.count)).sorted()
        }
        self.styles = styles
    }

    /// 业务作用：TOML 词表按原字节精确项或 caret 前缀授予类别，资源拼写不被隐式改写。
    /// 参数说明:
    /// - word: 已转为 ASCII 小写的最多七个原字节的 ASCII 小写候选。
    /// - group: 本轮优先级对应的明确词表位置。
    /// - budget: 所有名称和前缀比较共享的步骤与截止预算。
    /// 返回：精确项或明确前缀匹配时为真；超量或取消时抛错以拒绝部分分类。
    func contains(_ word: Data, group: Int, budget: inout ANSILexingBudget) throws -> Bool {
        try budget.consume()
        if groups[group].contains(word) {
            return true
        }
        for length in prefixLengths[group] {
            try budget.consume()
            if length > word.count {
                break
            }
            if prefixGroups[group].contains(Data(word.prefix(length))) {
                return true
            }
        }
        return false
    }
}
