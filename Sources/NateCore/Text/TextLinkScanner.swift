import Foundation

struct TextLinkCandidate: Sendable {
    let range: Range<Int>
    let candidateUpper: Int
    let schemeLength: Int
    let prefixLength: Int
}

private struct TextLinkPrefix {
    let values: [UInt32]
    let schemeLength: Int
}

struct TextLinkScanner {
    let values: [UInt32]
    let byteOffsets: [Int]
    private let enabled: Bool
    private let prefixes: [UInt32: [TextLinkPrefix]]
    private var work: TextLinkWork

    /// 业务作用：固定至多 64 KiB 的原文字面及完整标量坐标，协议索引不读取外部注册表或访问网络。
    /// 参数说明:
    /// - text: 已经固定来源且完整边界已确认的原文片段。
    /// - settings: 已完整验证的链接显示与附加协议配置。
    /// - deadline: 片段扫描、协议比较及尾部裁剪共同的截止。
    /// - permit: 当前正文和配置仍有本次计算资格。
    /// 返回：固定标量与原字节映射的扫描器；容量、来源或截止不合规时拒绝建立。
    init(
        text: String,
        settings: TextLinkSettings,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws {
        guard text.utf8.count <= 65_536 else {
            throw NateError.message("单次链接识别原文超过 64 KiB，未截断候选。")
        }
        var work = TextLinkWork(deadline: deadline, permit: permit)
        try work.check()
        var values: [UInt32] = []
        var byteOffsets = [0]
        var byteOffset = 0
        for scalar in text.unicodeScalars {
            try work.consume()
            values.append(scalar.value)
            byteOffset += scalar.utf8.count
            byteOffsets.append(byteOffset)
        }
        var prefixes: [UInt32: [TextLinkPrefix]] = [:]
        for prefix in settings.prefixes {
            let units = prefix.unicodeScalars.map {
                TextLinkCharacters.folded($0.value)
            }
            guard let first = units.first, let colon = units.firstIndex(of: 58) else {
                throw NateError.message("链接协议缺少完整已验证定义，未建立部分索引。")
            }
            try work.consume(units.count)
            prefixes[first, default: []].append(
                TextLinkPrefix(values: units, schemeLength: colon + 1)
            )
        }
        self.values = values
        self.byteOffsets = byteOffsets
        self.enabled = settings.mode != .disabled
        self.prefixes = prefixes
        self.work = work
        try self.work.check()
    }

    /// 业务作用：按真实前导边界识别完整协议并裁剪外层标点，返回前不泄露部分扫描结果。
    /// 参数说明: 无。
    /// 返回：至多 4096 个原顺序候选；关闭显示时为空，超量、取消或来源失效时整份失败。
    mutating func candidates() throws -> [TextLinkCandidate] {
        try work.check()
        guard enabled else {
            return []
        }
        var result: [TextLinkCandidate] = []
        var current = 0
        while current < values.count {
            try work.consume()
            guard TextLinkCharacters.isLetter(values[current]),
                current == 0 || TextLinkCharacters.isSchemeDelimiter(values[current - 1]),
                let prefix = try matchingPrefix(at: current)
            else {
                current += 1
                continue
            }
            let end = try scanEnd(from: current + prefix.schemeLength)
            if end > current + prefix.schemeLength {
                guard result.count < 4096 else {
                    throw NateError.message("当前链接页超过 4096 个候选，未发布部分结果。")
                }
                result.append(
                    TextLinkCandidate(
                        range: current..<(try trimmedEnd(from: current, to: end)),
                        candidateUpper: end,
                        schemeLength: prefix.schemeLength,
                        prefixLength: prefix.values.count
                    )
                )
            }
            current = max(current + 1, end)
        }
        try work.check()
        return result
    }

    /// 业务作用：已验证协议只按字面及 ASCII 大小写比较，同一起点优先采用更完整的协议前缀。
    /// 参数说明:
    /// - position: 已确认具有协议开始边界的标量位置。
    /// 返回：完整匹配的最长协议定义；没有匹配时为空，不消费其它正文位置。
    private mutating func matchingPrefix(at position: Int) throws -> TextLinkPrefix? {
        var selected: TextLinkPrefix?
        for prefix in prefixes[TextLinkCharacters.folded(values[position])] ?? [] {
            guard prefix.values.count <= values.count - position else {
                continue
            }
            var matches = true
            for offset in prefix.values.indices {
                try work.consume()
                if TextLinkCharacters.folded(values[position + offset]) != prefix.values[offset] {
                    matches = false
                    break
                }
            }
            if matches, prefix.values.count > (selected?.values.count ?? 0) {
                selected = prefix
            }
        }
        return selected
    }

    /// 业务作用：路径、查询、引用值及片段保持独立状态，查询引用中的空格不能提前切断同一候选。
    /// 参数说明:
    /// - start: 协议冒号之后的第一个标量位置。
    /// 返回：完整候选的半开末端，控制字符和非法状态后继不进入候选。
    private mutating func scanEnd(from start: Int) throws -> Int {
        enum State {
            case path
            case query
            case afterDelimiter
            case quoted
            case afterQuote
            case fragment
        }
        var state = State.path
        var quote: UInt32 = 0
        var current = start
        while current < values.count {
            try work.consume()
            let value = values[current]
            switch state {
            case .path:
                if value == 63 {
                    state = .query
                }
                else if value == 35 {
                    state = .fragment
                }
                else if !TextLinkCharacters.isText(value) {
                    return current
                }
            case .query:
                if value == 35 {
                    state = .fragment
                }
                else if TextLinkCharacters.isQueryDelimiter(value) {
                    state = .afterDelimiter
                }
                else if !TextLinkCharacters.isText(value) {
                    return current
                }
            case .afterDelimiter:
                if [39, 34, 96].contains(value) {
                    quote = value
                    state = .quoted
                }
                else if [40, 91, 123].contains(value) {
                    quote = value == 40 ? 41 : (value == 91 ? 93 : 125)
                    state = .quoted
                }
                else if TextLinkCharacters.isText(value) {
                    state = .query
                }
                else {
                    return current
                }
            case .quoted:
                if value < 32 {
                    return current
                }
                if value == quote {
                    state = .afterQuote
                }
            case .afterQuote:
                guard TextLinkCharacters.isQueryDelimiter(value) else {
                    return current
                }
                state = .afterDelimiter
            case .fragment:
                if value != 63, !TextLinkCharacters.isText(value) {
                    return current
                }
            }
            current += 1
        }
        return current
    }

    /// 业务作用：外层单引号及反引号和末尾标点只裁剪明确多余部分，路径内已配对括号保持完整。
    /// 参数说明:
    /// - start: 原候选的标量起点。
    /// - upper: 扫描状态已经确认的原候选末端。
    /// 返回：按原顺序完成外层与尾部裁剪后的半开末端，不改动任何原文。
    private mutating func trimmedEnd(from start: Int, to upper: Int) throws -> Int {
        var end = upper
        if start > 0, [39, 96].contains(values[start - 1]), values[end - 1] == values[start - 1] {
            end -= 1
        }
        while end - start > 1 {
            try work.consume()
            let last = values[end - 1]
            if [46, 44, 58, 59, 63, 33, 35].contains(last) {
                end -= 1
                continue
            }
            guard last == 41 || last == 93 else {
                break
            }
            let opening: UInt32 = last == 41 ? 40 : 91
            var count = 0
            var previous = end - 1
            while previous > start {
                previous -= 1
                try work.consume()
                if values[previous] == last {
                    count += 1
                }
                if values[previous] == opening {
                    guard count > 0 else {
                        return end
                    }
                    count -= 1
                }
            }
            guard count == 0 else {
                break
            }
            end -= 1
        }
        return end
    }
}
