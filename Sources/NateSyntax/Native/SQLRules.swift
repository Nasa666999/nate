import Foundation

private struct SQLRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct SQLRules: Sendable {
    static let groupNames = [
        "instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6",
    ]
    let identity: Data
    let groups: [Set<Data>]
    let prefixes: [Set<Data>]
    let prefixLengths: [[Int]]
    let abbreviations: [UInt8: [[UInt8]]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：SQL 固定主要、数据库对象、文档、SQL*Plus 与四组用户名称及完整样式。
    /// 参数说明:
    /// - language: 当前明确的 SQL 语言资源。
    /// - deadline: 所属词法操作的共同截止。
    /// 返回：完整有界规则；缺少字段、样式或预算时不授予词法资格。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "sql", let source = language.keywordGroups,
            let styles = language.lexicalStyles, styles.count <= 256,
            Self.groupNames.allSatisfy({
                source[$0] != nil
            }),
            (0...24).allSatisfy({
                styles[String($0)] != nil
            }),
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024, count = 0
        var used: [String: [String]] = [:]
        // 原字段先有界，规则身份编码不能先为不受信任的词表分配无限内存。
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
        let value = SQLRuleIdentity(
            groups: used,
            styles: styles
        )
        guard let encoded = try? encoder.encode(value), encoded.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = encoded
        groups = Self.groupNames.map { name in
            Set(
                (used[name] ?? []).map { word in
                    Data(
                        word.utf8.map { byte in
                            byte >= 65 && byte <= 90 ? byte + 32 : byte
                        }
                    )
                }
            )
        }
        prefixes = groups.map { words in
            Set(
                words.filter {
                    $0.first == 94
                }.map {
                    Data($0.dropFirst())
                }
            )
        }
        prefixLengths = prefixes.map { words in
            Set(words.map(\.count)).sorted()
        }
        var abbreviated: [UInt8: [[UInt8]]] = [:]
        for word in groups[3] where word.contains(126) {
            if let first = word.first {
                abbreviated[first, default: []].append(Array(word))
            }
        }
        abbreviations = abbreviated
        self.styles = styles
    }

    /// 业务作用：名称按 SQL 原生顺序取得关键字、对象、SQL*Plus 或用户类别。
    /// 参数说明:
    /// - bytes: 已确认完整的 ASCII 名称。
    /// - budget: 当前分类共享的步骤与截止预算。
    /// 返回：最多 999 个候选字节参与分类；未知名称保持标识符身份。
    func identifier(_ bytes: ArraySlice<UInt8>, budget: inout ANSILexingBudget) throws -> UInt8 {
        let word = Data(
            bytes.prefix(999).map { byte in
                byte >= 65 && byte <= 90 ? byte + 32 : byte
            }
        )
        for (group, style) in [(0, 5), (1, 16), (3, 8), (4, 19), (5, 20), (6, 21), (7, 22)] {
            if try contains(word, group: group, budget: &budget) {
                return UInt8(style)
            }
            if group == 3, try abbreviated(word, budget: &budget) {
                return UInt8(style)
            }
        }
        return 11
    }

    /// 业务作用：精确名称及 caret 前缀在原生 ASCII 小写后匹配，不进行 Unicode 归一化。
    /// 参数说明:
    /// - word: 已截取的候选原字节。
    /// - group: 当前明确词表的位置。
    /// - budget: 每次前缀比较共享的操作预算。
    /// 返回：精确项或明确前缀授予名称身份时为真。
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
            if prefixes[group].contains(Data(word.prefix(length))) {
                return true
            }
        }
        return false
    }

    /// 业务作用：SQL*Plus 的 tilde 缩写保留实际最低长度和后继拼写，不扩展为无限前缀。
    /// 参数说明:
    /// - word: 最多 999 字节的 ASCII 小写候选。
    /// - budget: 所有缩写比较共享的操作预算。
    /// 返回：符合原生缩写位置和完整候选终止条件时为真。
    func abbreviated(_ word: Data, budget: inout ANSILexingBudget) throws -> Bool {
        guard let first = word.first else {
            return false
        }
        let candidate = Array(word) + [0]
        for original in abbreviations[first] ?? [] {
            try budget.consume()
            let pattern = original + [0]
            var a = 1, b = 1, shortened = false
            if pattern[a] == 126 {
                shortened = true
                a += 1
            }
            if candidate[1] != pattern[a] {
                continue
            }
            while pattern[a] != 0 && pattern[a] == candidate[b] {
                try budget.consume()
                a += 1
                if pattern[a] == 126 {
                    shortened = true
                    a += 1
                }
                b += 1
            }
            if (pattern[a] == 0 || shortened) && candidate[b] == 0 {
                return true
            }
        }
        return false
    }
}
