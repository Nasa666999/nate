import Foundation

final class UDLLiteralMatcher {
    private let patterns: [String]
    private let ignoreCase: Bool
    private var edges: [UInt64: Int] = [:]
    private var terminals: [Int: Int] = [:]
    private var fallback: [Int] = []

    /// 业务作用：字面候选按原字节建立共享前缀索引，忽略大小写的非 ASCII 规则保留完整小写比较。
    /// 参数说明:
    /// - patterns: 当前组按原始顺序排列的候选。
    /// - ignoreCase: 是否采用定义的小写比较规则。
    /// - budget: 本行所有索引及匹配共同拥有的预算。
    /// 返回：完整且有界的索引，任一容量或资格不足时不发布部分规则。
    init(patterns: [String], ignoreCase: Bool, budget: UDLScanBudget) throws {
        self.patterns = patterns
        self.ignoreCase = ignoreCase
        try budget.reserveNode()
        var nextNode = 1
        for (index, pattern) in patterns.enumerated() {
            try budget.consume(pattern.utf8.count + 1)
            let bytes = Array(pattern.utf8)
            guard !bytes.isEmpty else {
                continue
            }
            if ignoreCase,
                bytes.contains(where: {
                    $0 >= 128
                })
            {
                fallback.append(index)
                continue
            }
            var node = 0
            for byte in bytes {
                let key = UInt64(node) << 8 | UInt64(Self.fold(byte, enabled: ignoreCase))
                if let child = edges[key] {
                    node = child
                }
                else {
                    try budget.reserveNode()
                    edges[key] = nextNode
                    node = nextNode
                    nextNode += 1
                }
            }
            if terminals[node] == nil {
                terminals[node] = index
            }
        }
    }

    /// 业务作用：同一位置只走实际字面前缀，不逐字节遍历整份 ASCII 词表。
    /// 参数说明:
    /// - bytes: 当前完整行原字节。
    /// - offset: 已确认的标量边界。
    /// - budget: 所有组共用的工作量和截止。
    /// 返回：最长且同长优先原顺序的候选；没有匹配时为空。
    func longest(in bytes: [UInt8], at offset: Int, budget: UDLScanBudget) throws -> String? {
        var node = 0, cursor = offset
        var best: Int?
        while cursor < bytes.count {
            try budget.consume()
            let key = UInt64(node) << 8 | UInt64(Self.fold(bytes[cursor], enabled: ignoreCase))
            guard let child = edges[key] else {
                break
            }
            node = child
            cursor += 1
            if let index = terminals[node] {
                best = index
            }
        }
        for index in fallback {
            let pattern = patterns[index]
            let count = pattern.utf8.count
            try budget.consume()
            guard count <= bytes.count - offset else {
                continue
            }
            try budget.consume(count)
            let candidate = String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
            if candidate.lowercased().utf8.elementsEqual(pattern.lowercased().utf8),
                best == nil || count > patterns[best ?? index].utf8.count
                    || count == patterns[best ?? index].utf8.count && index < (best ?? index)
            {
                best = index
            }
        }
        return best.map {
            patterns[$0]
        }
    }

    /// 业务作用：ASCII 规则的大小写折叠不改变长度，非 ASCII 原字节不会被当作 ASCII 字母。
    /// 参数说明:
    /// - byte: 当前规则或正文原字节。
    /// - enabled: 定义是否忽略大小写。
    /// 返回：需要时折叠 ASCII 大写，其它字节逐值保留。
    private static func fold(_ byte: UInt8, enabled: Bool) -> UInt8 {
        enabled && (65...90).contains(byte) ? byte + 32 : byte
    }
}
