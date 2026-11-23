import Foundation
import NateCore

private struct ASMRuleIdentity: Encodable {
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct ASMRules: Sendable {
    let identity: Data
    let keywords: [Set<Data>]
    let prefixes: [Set<Data>]
    let prefixLengths: [[Int]]
    let styles: [String: LanguageTokenStyle]

    /// 业务作用：汇编八组有序词表与十七类样式共同固定，指令、字符串及注释状态不能沿另一份规则继续。
    /// 参数说明:
    /// - language: 当前明确语言的完整八组词表和样式。
    /// - deadline: 规则准备与正文扫描共享的截止。
    /// 返回：至多 65536 个词、4 MiB 原字段及 8 MiB 编码的完整规则；缺失、超量或取消时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "asm", let input = language.keywordGroups,
            ["instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6"].allSatisfy({
                input[$0] != nil
            }),
            let styles = language.lexicalStyles, styles.count <= 256,
            (0...16).allSatisfy({
                styles[String($0)] != nil
            }), !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        let groups = Dictionary(
            uniqueKeysWithValues: [
                "instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6",
            ].map { name in
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
        let value = ASMRuleIdentity(
            groups: groups,
            styles: styles
        )
        guard let data = try? encoder.encode(value), data.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        identity = data
        let names = ["instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6"]
        keywords = names.map { name in
            Set(
                (groups[name] ?? []).map {
                    Data($0.utf8.map(ASMCharacters.folded))
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

    /// 业务作用：汇编候选与词表按原生 ASCII 小写比较，指令及操作数优先级由词法分支决定。
    /// 参数说明:
    /// - word: 原生最多九十九原字节的已确认 ASCII 小写名称候选。
    /// - group: CPU、FPU、寄存器、指令、操作数、扩展及两组折叠词的明确通道。
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
