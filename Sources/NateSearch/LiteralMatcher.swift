import Foundation
import NateCore

enum LiteralMatcher {
    /// 业务作用：普通与扩展模式使用线性匹配，长日志不消耗正则回溯预算。
    /// 参数说明:
    /// - snapshot: 不可变正文。
    /// - input: 对应 UTF-16 单元。
    /// - range: 当前搜索范围。
    /// - options: 大小写、全词与结果预算。
    /// 返回：不交叠的字面命中，取消与超时明确失败。
    static func find(snapshot: DocumentSnapshot, input: [UInt16], range: NSRange, options: SearchOptions)
        throws -> SearchResult
    {
        let query = options.mode == .extended ? ExtendedEscapes.decode(options.query) : options.query
        let pattern = query.utf16.map {
            fold($0, sensitive: options.caseSensitive)
        }
        guard !pattern.isEmpty else {
            throw NateError.message("扩展后的查找内容为空。")
        }
        var prefix = [Int](repeating: 0, count: pattern.count)
        var j = 0
        if pattern.count > 1 {
            for i in 1..<pattern.count {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        for i in range.location..<(range.location + range.length) {
            if i % 4096 == 0 {
                try Task.checkCancellation()
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
                let start = i + 1 - pattern.count
                let end = i + 1
                if !options.wholeWord
                    || (start == 0 || !word(input[start - 1])) && (end == input.count || !word(input[end]))
                {
                    let range = NSRange(location: start, length: pattern.count)
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
