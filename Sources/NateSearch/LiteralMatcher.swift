import Foundation
import NateCore

enum LiteralMatcher {
    /// 业务作用：普通与扩展模式使用线性匹配，长日志不消耗正则回溯预算。
    /// 参数说明:
    /// - snapshot: 不可变正文。
    /// - input: 对应 UTF-16 单元。
    /// - range: 当前搜索范围。
    /// - options: 大小写、全词与结果预算。
    /// - firstOnly: 是否在首个完整命中后停止。
    /// - backwards: 是否从范围终点倒向起点匹配，保留反向查找的重叠候选。
    /// - permit: 显式调用权限，脱离 Swift Task 的队列同样据此停止计算。
    /// - onHit: 非空时只同步累计命中，不保留坐标列表或申请展示额度。
    /// 返回：普通调用提供不交叠的字面命中；同步枚举调用不保留列表，取消与超时都终止整个调用。
    static func find(
        snapshot: DocumentSnapshot,
        input: [UInt16],
        range: NSRange,
        options: SearchOptions,
        firstOnly: Bool = false,
        backwards: Bool = false,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        onHit: ((NSRange) throws -> Void)? = nil
    )
        throws -> SearchResult
    {
        try Task.checkCancellation()
        // 显式撤销先于查询投影和前缀表分配，独立队列不能继续处理已经失效的动作。
        guard permit() else {
            throw CancellationError()
        }
        try options.validateInput()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let query = options.mode == .extended ? ExtendedEscapes.decode(options.query) : options.query
        let units = Array(query.utf16)
        let pattern = (backwards ? Array(units.reversed()) : units).map {
            fold($0, sensitive: options.caseSensitive)
        }
        guard !pattern.isEmpty else {
            throw NateError.message("扩展后的查找内容为空。")
        }
        var prefix = [Int](repeating: 0, count: pattern.count)
        var j = 0
        if pattern.count > 1 {
            for i in 1..<pattern.count {
                if i % 4096 == 0 {
                    try Task.checkCancellation()
                    guard permit() else {
                        throw CancellationError()
                    }
                    guard ContinuousClock.now < deadline else {
                        throw NateError.message("字面搜索超过 10 秒预算。")
                    }
                }
                while j > 0 && pattern[i] != pattern[j] {
                    j = prefix[j - 1]
                }
                if pattern[i] == pattern[j] {
                    j += 1
                }
                prefix[i] = j
            }
        }
        var hits: [SearchHit] = []
        j = 0
        for offset in 0..<range.length {
            let i = backwards ? range.location + range.length - 1 - offset : range.location + offset
            if offset % 4096 == 0 {
                try Task.checkCancellation()
                guard permit() else {
                    throw CancellationError()
                }
                guard ContinuousClock.now < deadline else {
                    throw NateError.message("字面搜索超过 10 秒预算。")
                }
            }
            let unit = fold(input[i], sensitive: options.caseSensitive)
            while j > 0 && unit != pattern[j] {
                j = prefix[j - 1]
            }
            if unit == pattern[j] {
                j += 1
            }
            if j == pattern.count {
                let start = backwards ? i : i + 1 - pattern.count
                let end = start + pattern.count
                if !options.wholeWord
                    || (start == 0 || !word(input[start - 1])) && (end == input.count || !word(input[end]))
                {
                    let range = NSRange(
                        location: start,
                        length: pattern.count
                    )
                    if let onHit {
                        try onHit(range)
                    }
                    else {
                        hits.append(
                            SearchHit(
                                utf16Range: range,
                                range: snapshot.text.byteRange(range),
                                captures: [0: range]
                            )
                        )
                        guard hits.count <= options.maxMatches else {
                            throw NateError.message("命中超过结果上限，请缩小范围。")
                        }
                    }
                    if firstOnly {
                        break
                    }
                    j = 0
                }
                else {
                    j = prefix[j - 1]
                }
            }
        }
        return SearchResult(
            documentID: snapshot.id,
            revision: snapshot.revision,
            options: options,
            hits: hits
        )
    }

    /// 业务作用：大小写比较保持 UTF-16 单元长度，不归一化组合字符。
    /// 参数说明:
    /// - unit: 原单元。
    /// - sensitive: 是否保持原大小写。
    /// 返回：单单元小写映射，多单元映射保留原值。
    static func fold(_ unit: UInt16, sensitive: Bool) -> UInt16 {
        if sensitive || unit < 65 {
            return unit
        }
        if unit <= 90 {
            return unit + 32
        }
        if unit < 128 {
            return unit
        }
        guard let scalar = Unicode.Scalar(unit) else {
            return unit
        }
        let lowered = Array(String(scalar).lowercased().utf16)
        return lowered.count == 1 ? lowered[0] : unit
    }

    /// 业务作用：全词判断与 Unicode 字母数字边界一致。
    /// 参数说明:
    /// - unit: 邻接 UTF-16 单元。
    /// 返回：下划线、字母和数字为词内容。
    static func word(_ unit: UInt16) -> Bool {
        unit == 95
            || (Unicode.Scalar(unit).map {
                CharacterSet.alphanumerics.contains($0)
            } ?? false)
    }
}
