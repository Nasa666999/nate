struct SpiceRules {
    private struct Group {
        var words: Set<[UInt8]> = []
        var prefixes: [[UInt8]] = []
    }

    private let groups: [Group]

    /// 业务作用：固定 SPICE 命令、函数与参数的三组原词表及其优先顺序，词表超限时拒绝进入逐行着色。
    /// 参数说明:
    /// - language: 当前 SPICE 定义关联的完整原词表。
    /// - deadline: 词法任务准备、逐行扫描和发布共用的截止。
    /// 返回：三组全部通过容量及原字节验证时提供规则。取消、超量或字段缺失时为空。
    init?(language: LanguageDefinition, deadline: ContinuousClock.Instant) {
        guard language.id == "spice", let source = language.keywordGroups else {
            return nil
        }
        var prepared: [Group] = []
        var remainingWords = 65_536
        var remainingBytes = 4_194_304
        for field in ["instre1", "instre2", "type1"] {
            guard let words = source[field], words.count <= remainingWords else {
                return nil
            }
            remainingWords -= words.count
            var group = Group()
            for word in words {
                guard !Task.isCancelled, ContinuousClock.now < deadline,
                    word.utf8.count <= remainingBytes, !word.utf8.contains(0)
                else {
                    return nil
                }
                remainingBytes -= word.utf8.count
                let raw = Array(word.utf8)
                group.words.insert(raw)
                if raw.first == 94 {
                    group.prefixes.append(Array(raw.dropFirst()))
                }
            }
            prepared.append(group)
        }
        groups = prepared
    }

    /// 业务作用：候选按命令、函数和参数顺序匹配，精确词与 `^` 前缀均只识别原词表规定的字节。
    /// 参数说明:
    /// - candidate: 从当前完整词元取得的有效原比较字节。
    /// - budget: 当前扫描共享的比较预算。
    /// 返回：首个命中词表的样式号，普通名称使用标识样式，耗尽预算时终止整次扫描。
    func style(of candidate: [UInt8], budget: inout ANSILexingBudget) throws -> Int {
        for (index, group) in groups.enumerated() {
            if group.words.contains(candidate) {
                return index + 2
            }
            for prefix in group.prefixes {
                try budget.consume()
                guard prefix.count <= candidate.count else {
                    continue
                }
                var matched = true
                for (left, right) in zip(prefix, candidate) {
                    try budget.consume()
                    if left != right {
                        matched = false
                        break
                    }
                }
                if matched {
                    return index + 2
                }
            }
        }
        return 1
    }
}
