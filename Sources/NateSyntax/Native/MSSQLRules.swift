import Foundation

private struct MSSQLRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct MSSQLRules: Sendable {
    static let groupNames = [
        "instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6",
    ]
    let identity: Data
    let groups: [Set<Data>]
    let prefixGroups: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：T-SQL 固定七类名称与完整样式，字段在编码前通过容量和截止门禁。
    /// 参数说明:
    /// - language: 当前明确的 T-SQL 语言资源。
    /// - deadline: 所属词法操作的共同截止。
    /// 返回：最多 65536 项、4 MiB 原字段及 8 MiB 编码的完整规则；缺失或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        // 缺少任一类别时不能借用别处的样式，否则引用列名和注释会丢失自己的结构身份。
        guard language.id == "mssql", let source = language.keywordGroups,
            let styles = language.lexicalStyles, styles.count <= 256,
            Self.groupNames.allSatisfy({
                source[$0] != nil
            }),
            (0...16).allSatisfy({
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
        let value = MSSQLRuleIdentity(
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

    /// 业务作用：按原生名称截取和上下文优先顺序区分 T-SQL 类型、语句、全局及系统名称。
    /// 参数说明:
    /// - bytes: 已确认完整的 ASCII 名称原字节。
    /// - prefersType: 前置普通名称或引用列名是否授予类型优先。
    /// - global: 是否为双 at 符号开端的全局名称。
    /// 返回：完整名称的原生类别，未知全局或普通名称保持标识符身份。
    func identifier(_ bytes: ArraySlice<UInt8>, prefersType: Bool, global: Bool) -> UInt8 {
        let lowered = Data(
            bytes.prefix(128).map { byte in
                byte >= 65 && byte <= 90 ? byte + 32 : byte
            }
        )
        if global {
            return contains(Data(lowered.dropFirst(2)), group: 3) ? 12 : 6
        }
        if let first = bytes.first, first >= 48 && first <= 57 || first == 46 {
            return 3
        }
        let order =
            prefersType
            ? [(1, 10), (6, 5), (0, 9), (2, 11), (4, 13), (5, 14)]
            : [(6, 5), (0, 9), (2, 11), (4, 13), (5, 14), (1, 10)]
        for (group, style) in order where contains(lowered, group: group) {
            return UInt8(style)
        }
        return 6
    }

    /// 业务作用：词表中的 caret 前缀只按原字节扩展名称，保留原生优先顺序与大小写规则。
    /// 参数说明:
    /// - word: 已按原生长度截取并转为 ASCII 小写的候选名称。
    /// - group: 当前优先级对应的词表位置。
    /// 返回：精确名称或明确前缀匹配时为真；前缀比较最多覆盖候选的 129 种字节长度。
    func contains(_ word: Data, group: Int) -> Bool {
        if groups[group].contains(word) {
            return true
        }
        for length in prefixLengths[group] {
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
