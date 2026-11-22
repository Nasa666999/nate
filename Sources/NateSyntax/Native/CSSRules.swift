import Foundation

private struct CSSRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct CSSRules: Sendable {
    static let groupNames = [
        "instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6",
    ]
    let identity: Data
    let groups: [Set<Data>]
    let prefixGroups: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：CSS 固定八组名称与完整样式，字段在编码前通过容量和截止门禁。
    /// 参数说明:
    /// - language: 当前明确的 CSS 语言资源。
    /// - deadline: 所属词法操作的共同截止。
    /// 返回：最多 65536 项、4 MiB 原字段及 8 MiB 编码的完整规则；缺失或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        // 缺少任一类别时不能借用别处的样式，否则选择器、属性和字符串会丢失自己的类别。
        guard language.id == "css", let source = language.keywordGroups,
            let styles = language.lexicalStyles, styles.count <= 256,
            Self.groupNames.allSatisfy({
                source[$0] != nil
            }),
            (0...23).allSatisfy({
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
        let value = CSSRuleIdentity(
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

    /// 业务作用：CSS 从当前完整词法段取得有界候选，保留原生 NUL 终止和 ASCII 小写规则。
    /// 参数说明:
    /// - prefix: 当前 SetState 段最多九十九个原字节。
    /// 返回：跳过前置非名称字节后的候选，不进行 Unicode 归一化。
    static func candidate(_ prefix: [UInt8]) -> Data {
        let bytes = prefix.prefix(99).prefix(while: {
            $0 != 0
        }).map { byte in
            byte >= 65 && byte <= 90 ? byte + 32 : byte
        }
        let start =
            bytes.firstIndex(where: { byte in
                byte >= 128 || byte >= 48 && byte <= 57 || byte >= 65 && byte <= 90
                    || byte >= 97 && byte <= 122 || byte == 45 || byte == 95
            }) ?? bytes.endIndex
        return Data(bytes[start...])
    }

    /// 业务作用：CSS 词表按原字节精确项或 caret 前缀授予类别，资源拼写不被隐式改写。
    /// 参数说明:
    /// - word: 已截取并转为 ASCII 小写的候选。
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
