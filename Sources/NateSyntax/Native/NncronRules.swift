import Foundation
import NateCore

private struct NncronRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct NncronRules: Sendable {
    let identity: Data
    let keywords: [Set<Data>]
    let prefixes: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：nnCron 三组有序词表与十一类样式共同固定，环境变量与字符串状态不能沿另一份规则继续。
    /// 参数说明:
    /// - language: 当前明确语言的完整三组词表和样式。
    /// - deadline: 规则准备与正文扫描共享的截止。
    /// 返回：至多 65536 个词、4 MiB 原字段及 8 MiB 编码的完整规则；缺失、超量或取消时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "nncrontab", let input = language.keywordGroups,
            ["instre1", "instre2", "type1"].allSatisfy({
                input[$0] != nil
            }),
            let styles = language.lexicalStyles, styles.count <= 256,
            (0...10).allSatisfy({
                styles[String($0)] != nil
            }), !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        let groups = Dictionary(
            uniqueKeysWithValues: ["instre1", "instre2", "type1"].map { name in
                (name, input[name]!)
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
        let value = NncronRuleIdentity(
            groups: groups,
            styles: styles
        )
        guard let data = try? encoder.encode(value), data.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        let names = ["instre1", "instre2", "type1"]
        keywords = names.map { name in
            Set(
                groups[name]!.map {
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

    /// 业务作用：nnCron 名称保持原始大小写和完整字节，分组优先级由原生词法分支决定。
    /// 参数说明:
    /// - word: 当前完整名称的原字节，不截取固定长度前缀。
    /// - group: 节与 Forth、关键字或修饰词的明确有序通道。
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
            if prefixes[group].contains(Data(word.prefix(length))) {
                return true
            }
        }
        return false
    }
}
