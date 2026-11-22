import Foundation

private struct ScriptRuleIdentity: Encodable {
    let language: String
    let groups: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

struct ScriptRules: Sendable {
    static let groupNames = [
        "instre1", "type1", "cppDocumentation", "instre2", "substyle1", "substyle2",
        "substyle3", "substyle4", "substyle5", "substyle6", "substyle7", "substyle8",
    ]
    let identity: Data
    let groups: [Set<Data>]
    let styles: [String: LanguageTokenStyle]
    let interpolatesTemplates: Bool

    /// 业务作用：脚本语言固定各自的词表、文档词与用户子样式，完整资源确认后才允许共享词法读取。
    /// 参数说明:
    /// - language: 当前明确的 JavaScript 或 TypeScript 定义。
    /// - deadline: 资源准备和所属动作共用的截止。
    /// 返回：最多 65536 个词条、4 MiB 原始字段及 8 MiB 编码的完整规则；缺少字段或超量时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard ["javascript.js", "typescript"].contains(language.id), !Task.isCancelled,
            ContinuousClock.now < deadline, let source = language.keywordGroups,
            let styles = language.lexicalStyles, styles.count <= 256,
            Self.groupNames.allSatisfy({
                source[$0] != nil
            }),
            (Array(0...27) + Array(128...135)).allSatisfy({
                styles[String($0)] != nil
            })
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024
        var count = 0
        var used: [String: [String]] = [:]
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
        let value = ScriptRuleIdentity(
            language: language.id,
            groups: used,
            styles: styles
        )
        guard let data = try? encoder.encode(value), data.count <= 8 * 1024 * 1024,
            !Task.isCancelled, ContinuousClock.now < deadline
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
        self.styles = styles
        interpolatesTemplates = language.id == "javascript.js"
    }

    /// 业务作用：普通词表优先于八组用户子样式，用户同名声明按原顺序由后组覆盖。
    /// 参数说明:
    /// - bytes: 完整标识符的原字节，不执行 Unicode 归一化。
    /// 返回：对应原生类别；没有匹配时保持标识符类别。
    func identifier(_ bytes: Data) -> Int {
        for (group, style) in [(0, 5), (1, 16), (3, 19)] where groups[group].contains(bytes) {
            return style
        }
        for group in (4..<12).reversed() where groups[group].contains(bytes) {
            return group + 124
        }
        return 11
    }
}
