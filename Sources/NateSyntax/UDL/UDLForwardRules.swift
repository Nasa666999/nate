import Foundation

struct UDLForwardMatch {
    let text: String
    let group: Int
}

struct UDLForwardRules {
    private struct Field {
        let groups: [[String]]
        let patterns: [String]
        let owners: [Int]

        /// 业务作用：展开候选与原位置一一对应，重复文字也保留最早候选所属的起止组。
        /// 参数说明:
        /// - groups: 同一两位字段编号下按原顺序排列的候选组。
        /// 返回：连续字面索引及每个候选的所属位置。
        init(groups: [[String]]) {
            self.groups = groups
            var patterns: [String] = []
            var owners: [Int] = []
            for (index, group) in groups.enumerated() {
                for pattern in group {
                    patterns.append(pattern)
                    owners.append(index)
                }
            }
            self.patterns = patterns
            self.owners = owners
        }
    }
    private let fields: [Int: Field]
    let flattened: [Int: [String]]

    /// 业务作用：注释与分隔符保留每次同编号出现的位置，双括号中的替代项属于同一个对应组。
    /// 参数说明:
    /// - words: 保留双括号组语法的原字段。
    /// - maximumField: 当前注释或分隔符组允许的最大两位编号。
    /// - budget: 规则展开和后续词法匹配共同持有的预算。
    /// 返回：有界且保留位置身份的前向规则；超量时不发布部分字段。
    init(words: [String], maximumField: Int, budget: UDLScanBudget) throws {
        var groups: [Int: [[String]]] = [:]
        for word in words {
            try budget.consume(word.utf8.count + 1)
            guard let indexed = UDLIndexedRule.parse(word, maximum: maximumField) else {
                continue
            }
            let field = indexed.field
            let raw = indexed.body
            var alternatives: [String] = []
            if raw.utf8.prefix(2).elementsEqual([40, 40]), raw.utf8.suffix(2).elementsEqual([41, 41]) {
                let bytes = Array(raw.utf8.dropFirst(2).dropLast(2))
                var start = 0
                for index in 0...bytes.count where index == bytes.count || bytes[index] == 32 {
                    if index > start {
                        let part = String(decoding: bytes[start..<index], as: UTF8.self)
                        let values = part == "EOL" ? ["\r\n", "\n", "\r"] : [part]
                        for value in values {
                            if !alternatives.isEmpty {
                                // 一个原字段可以展开多个候选，追加前先取得完整资源容量。
                                try budget.reserveAlternative()
                            }
                            try budget.consume(value.utf8.count + 1)
                            alternatives.append(value)
                        }
                    }
                    start = index + 1
                }
            }
            else if !raw.isEmpty {
                alternatives = [raw]
            }
            if !alternatives.isEmpty {
                groups[field, default: []].append(alternatives)
            }
        }
        var fields: [Int: Field] = [:]
        var flattened: [Int: [String]] = [:]
        for (index, groups) in groups {
            let field = Field(groups: groups)
            fields[index] = field
            flattened[index] = field.patterns
        }
        self.fields = fields
        self.flattened = flattened
    }

    /// 业务作用：匹配开端时同时固定对应位置，后续结束符不能借其它开端的规则提前闭合当前上下文。
    /// 参数说明:
    /// - field: 实际两位字段编号。
    /// - key: 当前完整规则组的稳定索引身份。
    /// - bytes: 当前物理行原字节。
    /// - offset: 完整标量边界。
    /// - ignoreCase: 当前大小写选项。
    /// - budget: 本行共享的索引、候选与执行资格。
    /// 返回：完整匹配及所属起止位置，未命中时为空。
    func match(field: Int, key: String, bytes: [UInt8], offset: Int, ignoreCase: Bool, budget: UDLScanBudget)
        throws -> UDLForwardMatch?
    {
        guard let rules = fields[field],
            let index = try budget.longestIndex(
                key: key,
                patterns: rules.patterns,
                bytes: bytes,
                offset: offset,
                ignoreCase: ignoreCase
            )
        else {
            return nil
        }
        return UDLForwardMatch(text: rules.patterns[index], group: rules.owners[index])
    }

    /// 业务作用：闭合、转义和续行只读取命中开端对应的位置，缺失位置保持为空而不复用其它组。
    /// 参数说明:
    /// - field: 对应规则的两位字段编号。
    /// - group: 实际开端取得的原位置。
    /// 返回：该位置的完整替代项，原定义缺失时为空。
    func patterns(field: Int, group: Int) -> [String] {
        guard let rules = fields[field], rules.groups.indices.contains(group) else {
            return []
        }
        return rules.groups[group]
    }
}
