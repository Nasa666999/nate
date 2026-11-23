import Foundation
import NateCore

private struct AdaRuleIdentity: Encodable {
    let languageID: String
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct AdaRules: Sendable {
    let identity: Data
    let languageID: String
    let keywords: [Set<Data>]
    let prefixes: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：Ada 单词表与十二类有效样式共同固定，属性撇号状态不得承接另一份规则。
    /// 参数说明:
    /// - language: 当前 Ada 的完整关键词表和有效样式。
    /// - deadline: 规则准备与正文扫描共享的截止。
    /// 返回：至多 65536 个词、4 MiB 原字段及 8 MiB 编码的完整规则；缺失、超量或取消时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "ada", let input = language.keywordGroups,
            ["instre1"].allSatisfy({
                input[$0] != nil
            }),
            let styles = language.lexicalStyles, styles.count <= 256,
            (0...11).allSatisfy({
                styles[String($0)] != nil
            }), !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        let groups = Dictionary(
            uniqueKeysWithValues: ["instre1"].map { name in
                (name, input[name] ?? [])
            }
        )
        var wordsRemaining = 65_536
        for words in groups.values {
            guard words.count <= wordsRemaining else {
                return nil
            }
            wordsRemaining -= words.count
        }
        var remaining = 4 * 1024 * 1024
        // 未确认完整原字段之前不建立编码或集合，外部规则不能先占用不受限空间再报告拒绝。
        for word in groups.values.joined() {
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
        let value = AdaRuleIdentity(
            languageID: language.id,
            groups: groups,
            styles: styles
        )
        guard let data = try? encoder.encode(value), data.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        languageID = language.id
        let names = ["instre1"]
        keywords = names.map { name in
            Set(
                (groups[name] ?? []).map {
                    Data($0.utf8)
                }
            )
        }
        prefixes = keywords.map { words in
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
        self.styles = styles
    }

    /// 业务作用：Ada 完整名称按原生标量转换取得候选，词表原拼写及 caret 前缀资格保持。
    /// 参数说明:
    /// - word: 按原生规则转换后的完整名称，不截断长标识符。
    /// - group: Ada 唯一关键词通道，必须为零。
    /// - budget: 整轮词法计算共同的步骤与截止。
    /// 返回：原词表授予关键字身份时为真，资源拼写不被额外 Unicode 折叠；超量时拒绝部分扫描。
    func contains(_ word: Data, group: Int, budget: inout ANSILexingBudget) throws -> Bool {
        try budget.consume()
        guard keywords.indices.contains(group) else {
            throw NateError.invalidRange
        }
        if keywords[group].contains(word) {
            return true
        }
        for length in prefixLengths[group] {
            try budget.consume()
            if length > word.count {
                break
            }
            // Ada 使用完整名称，前缀复制的字节也占共同额度，长用户前缀不能放大逐名称工作量。
            for _ in 0..<length {
                try budget.consume()
            }
            if prefixes[group].contains(Data(word.prefix(length))) {
                return true
            }
        }
        return false
    }
}
