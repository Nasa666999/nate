import Foundation

private struct PascalRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct PascalRules: Sendable {
    let identity: Data
    let keywords: Set<Data>
    let prefixes: Set<Data>
    let prefixLengths: [Int]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：Pascal 单组关键字及十六类样式共同固定，属性、汇编和多行字面不能沿另一份规则继续。
    /// 参数说明:
    /// - language: 当前明确语言的完整词表和样式。
    /// - deadline: 规则准备与正文扫描共享的截止。
    /// 返回：至多 65536 个词、4 MiB 原字段及 8 MiB 编码的完整规则；缺失、超量或取消时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "pascal", let words = language.keywordGroups?["instre1"],
            words.count <= 65_536, let styles = language.lexicalStyles, styles.count <= 256,
            (0...15).allSatisfy({
                styles[String($0)] != nil
            }), !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024
        // 未确认完整原字段之前不建立编码或集合，外部规则不能先占用不受限空间再报告拒绝。
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
        let value = PascalRuleIdentity(
            groups: ["instre1": words],
            styles: styles
        )
        guard let data = try? encoder.encode(value), data.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        keywords = Set(
            words.map {
                Data($0.utf8)
            }
        )
        prefixes = Set(
            keywords.filter {
                $0.first == 94
            }.map {
                Data($0.dropFirst())
            }
        )
        prefixLengths = Set(prefixes.map(\.count)).sorted()
        self.styles = styles
    }

    /// 业务作用：Pascal 已按 ASCII 小写取得的候选只与原词表精确项或明确 caret 前缀比较。
    /// 参数说明:
    /// - word: 原生最多九十九字节的已确认名称候选。
    /// - budget: 整轮词法计算共同的步骤与截止。
    /// 返回：原词表授予关键字身份时为真，资源拼写不被额外 Unicode 折叠；超量时拒绝部分扫描。
    func contains(_ word: Data, budget: inout ANSILexingBudget) throws -> Bool {
        try budget.consume()
        if keywords.contains(word) {
            return true
        }
        for length in prefixLengths {
            try budget.consume()
            if length > word.count {
                break
            }
            if prefixes.contains(Data(word.prefix(length))) {
                return true
            }
        }
        return false
    }
}
