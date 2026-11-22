import Foundation

private struct RustRuleIdentity: Encodable {
    let words: [String: [String]]
    let styles: [String: LanguageTokenStyle]
}

extension RustLexing {
    /// 业务作用：先限制实际参与 Rust 的词表与样式，再建立稳定规则身份，未使用的其它语言元数据不扩大编码。
    /// 参数说明:
    /// - language: 当前固定的完整语言定义。
    /// - deadline: 规则预检、编码和后续扫描共用的截止。
    /// 返回：至多 4 MiB 的有效规则字节；超过 65536 个词条、原始字节容量或执行资格时为空。
    static func ruleIdentity(language: LanguageDefinition, deadline: ContinuousClock.Instant) -> Data? {
        guard !Task.isCancelled, ContinuousClock.now < deadline,
            let source = language.keywordGroups, let styles = language.lexicalStyles,
            styles.count <= 256,
            groupNames.allSatisfy({
                source[$0] != nil
            })
        else {
            return nil
        }
        var remaining = 4 * 1024 * 1024
        var count = 0
        var words: [String: [String]] = [:]
        for name in groupNames {
            let group = source[name] ?? []
            guard group.count <= 65_536 - count else {
                return nil
            }
            count += group.count
            for (index, word) in group.enumerated() {
                if index & 255 == 0, Task.isCancelled || ContinuousClock.now >= deadline {
                    return nil
                }
                guard !word.isEmpty, word.utf8.count <= remaining,
                    !word.utf8.contains(where: {
                        $0 <= 32
                    })
                else {
                    return nil
                }
                remaining -= word.utf8.count
            }
            words[name] = group
        }
        for (key, style) in styles {
            guard key.utf8.count <= 32 else {
                return nil
            }
            for value in [key, style.foreground ?? "", style.background ?? ""] {
                guard value.utf8.count <= remaining else {
                    return nil
                }
                remaining -= value.utf8.count
            }
        }
        // 编码只读取已经受限的有效字段，规则过量不能先建立任意大的 JSON 副本再决定拒绝。
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let identity = RustRuleIdentity(
            words: words,
            styles: styles
        )
        guard let data = try? encoder.encode(identity),
            data.count <= 4 * 1024 * 1024, !Task.isCancelled, ContinuousClock.now < deadline
        else {
            return nil
        }
        return data
    }
}
