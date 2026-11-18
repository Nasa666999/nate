import Foundation
import NateCore

enum LiteralMatcher {
    /// 业务作用：普通与扩展模式使用线性匹配，长日志不消耗正则回溯预算。
    /// 参数说明:
    /// - snapshot: 不可变正文。
    /// - input: 对应固定正文的有界 UTF-16 读取器。
    /// - range: 当前搜索范围。
    /// - options: 大小写、全词与结果预算。
    /// - firstOnly: 是否在首个完整命中后停止。
    /// - backwards: 是否从范围终点倒向起点匹配，保留反向查找的重叠候选。
    /// - permit: 显式调用权限，脱离 Swift Task 的队列同样据此停止计算。
    /// - onHit: 非空时只同步累计命中，不保留坐标列表或申请展示额度。
    /// 返回：完整源标量上的不交叠命中，折叠展开仍使用真实 UTF-16 范围；同步枚举不保留列表，取消或超时整体失败。
    static func find(
        snapshot: DocumentSnapshot,
        input: SearchInput,
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
        var pattern: [UInt32] = []
        for (index, scalar) in query.unicodeScalars.enumerated() {
            if index & 4095 == 0 {
                try checkpoint(permit, deadline: deadline)
            }
            let folded = UnicodeSearchFold.scalar(scalar.value, sensitive: options.caseSensitive)
            for index in 0..<folded.count {
                pattern.append(folded[index])
            }
        }
        if backwards {
            pattern.reverse()
        }
        guard !pattern.isEmpty else {
            throw NateError.message("扩展后的查找内容为空。")
        }
        var prefix = [Int](repeating: 0, count: pattern.count)
        var j = 0
        if pattern.count > 1 {
            for i in 1..<pattern.count {
                if i & 4095 == 0 {
                    try checkpoint(permit, deadline: deadline)
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
        try checkpoint(permit, deadline: deadline)
        var cursor = try LiteralScalarCursor(input: input, range: range, backwards: backwards)
        var origins = [Int](repeating: 0, count: pattern.count)
        var boundaries = [Bool](repeating: false, count: pattern.count)
        var write = 0
        var steps = 0
        var hits: [SearchHit] = []
        j = 0
        scan: while let scalar = try cursor.next() {
            if steps & 4095 == 0 {
                try checkpoint(permit, deadline: deadline)
            }
            steps += 1
            let folded = UnicodeSearchFold.scalar(scalar.value, sensitive: options.caseSensitive)
            for component in 0..<folded.count {
                let unit = folded[backwards ? folded.count - 1 - component : component]
                while j > 0 && unit != pattern[j] {
                    j = prefix[j - 1]
                }
                guard unit == pattern[j] else {
                    write = 0
                    continue
                }
                if j == 0 {
                    write = 0
                }
                origins[write] = backwards ? scalar.upper : scalar.lower
                boundaries[write] = component == 0
                write += 1
                if write == pattern.count {
                    write = 0
                }
                j += 1
                if j == pattern.count {
                    let start = backwards ? scalar.lower : origins[write]
                    let end = backwards ? origins[write] : scalar.upper
                    // 完整折叠可展开一个源字符，只有两侧都落在真实源标量边界才可发布，不能替换半个展开结果。
                    let complete = boundaries[write] && component == folded.count - 1
                    var whole = true
                    if complete && options.wholeWord {
                        let before = LiteralScalarCursor.ending(in: input, at: start)
                        let after = LiteralScalarCursor.starting(in: input, at: end)
                        let beforeWord =
                            before.map {
                                word($0.value)
                            } ?? false
                        let afterWord =
                            after.map {
                                word($0.value)
                            } ?? false
                        whole = !beforeWord && !afterWord
                    }
                    if complete && whole {
                        let range = NSRange(location: start, length: end - start)
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
                            break scan
                        }
                        j = 0
                        write = 0
                    }
                    else {
                        j = prefix[j - 1]
                    }
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

    /// 业务作用：正则字符类的单元比较保持 UTF-16 宽度，不借用普通搜索的多标量折叠。
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

    /// 业务作用：BMP 全词边界采用固定 Unicode 17.0.0 分类，与完整光标词选择保持一致。
    /// 参数说明:
    /// - unit: 邻接 UTF-16 单元。
    /// 返回：下划线、字母、标记和数字为词内容，半代理项不属于词字符。
    static func word(_ unit: UInt16) -> Bool {
        UnicodeWordClassification.contains(UInt32(unit))
    }

    /// 业务作用：补充平面相邻字母按完整标量判断，不能把代理对误当成全词分隔符。
    /// 参数说明:
    /// - scalar: 完整源 Unicode 标量。
    /// 返回：与光标词选择一致的固定默认词属性。
    static func word(_ scalar: UInt32) -> Bool {
        scalar <= 0xffff ? word(UInt16(scalar)) : UnicodeWordClassification.contains(scalar)
    }

    /// 业务作用：查询展开、前缀表和原文扫描共享取消与截止，失效任务不能继续占用搜索计算。
    /// 参数说明:
    /// - permit: 当前搜索仍有效的执行权限。
    /// - deadline: 本轮字面匹配共用的十秒截止。
    /// 返回：仍有权限与时间时继续，否则整轮失败而不发布部分结果。
    private static func checkpoint(_ permit: @Sendable () -> Bool, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("字面搜索超过 10 秒预算。")
        }
    }
}
