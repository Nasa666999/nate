import Foundation
import NateCore

enum MarkupIndentationPlan {
    private struct Tail {
        let kind: MarkupIndentationTag.Kind
        let end: Int
        let prefix: ByteRange
        let name: [UInt8]
    }

    /// 业务作用：用一次有界标记词法传播为全部真实换行目标确定同源标签、缩进和闭合位置。
    /// 参数说明:
    /// - snapshot: 全部目标共用的完整原始正文。
    /// - dialect: HTML 或 XML 的真实标签身份规则。
    /// - ranges: 核心已复验的全部真实替换范围。
    /// - deadline: 结构识别、准备与最终编辑共用的截止。
    /// - permit: 当前编辑事务继续准备的资格。
    /// 返回：完整逐目标动作；范围、来源、继续资格或容量不足时整体失败。
    static func actions(
        snapshot: DocumentSnapshot,
        dialect: MarkupDialect,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：在原文字节、作用域和目标行动间统一复验本次输入。
        /// 参数说明: 无。
        /// 返回：当前事务仍有效时通过，取消或期限失效时放弃完整结果。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("标记语言结构缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var groups: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            groups[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let lastLine = groups.keys.max() ?? 0
        guard lastLine < 1_048_576 else {
            throw NateError.message("标记语言缩进的前置传播超过一百万行。")
        }
        var remainingBytes = 64 * 1024 * 1024
        var remainingPrefixes = 1024 * 1024
        var prefixes: [ByteRange: String] = [:]
        var lexer = MarkupIndentationLexer(dialect: dialect)
        var scope = MarkupIndentationScope(dialect: dialect)
        var output: [ByteRange: NewlineIndentationAction] = [:]

        /// 业务作用：仅在真实目标需要时读取开端的原空白，同一来源只分配一次。
        /// 参数说明:
        /// - range: 标签开端物理行的已确认原缩进范围。
        /// 返回：所需的完整空格与 Tab 前缀；超过整批前缀预算时抛错。
        func prefix(for range: ByteRange) throws -> String {
            if range.isEmpty {
                return ""
            }
            if let cached = prefixes[range] {
                return cached
            }
            // 前缀与语法传播容量分别确认，远处和多目标对齐不能放大复制后才拒绝。
            guard range.count <= remainingPrefixes else {
                throw NateError.message("标记语言需要的完整原始前缀超过 1 MiB。")
            }
            remainingPrefixes -= range.count
            let result = text.text(in: range)
            prefixes[range] = result
            return result
        }

        for line in 0...lastLine {
            try check()
            let complete = text.lineRange(line)
            // 先确认所有前置原行预算，避免有些光标先使用未经完整确认的标签历史。
            guard complete.count <= 1024 * 1024, complete.count <= remainingBytes else {
                throw NateError.message("标记语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remainingBytes -= complete.count
            let row = text.lineRange(line, includeEnding: false)
            let bytes = Array(text.bytes(in: complete))
            let indentation = try followingSpace(bytes, from: 0, limit: row.count, check: check)
            let originalPrefix = ByteRange(row.lower, row.lower + indentation)
            var tags: [MarkupIndentationTag] = []
            var closedByStart: [Int: [UInt8]] = [:]
            let targets = groups[line] ?? []
            for (offset, byte) in bytes.enumerated() {
                if offset & 255 == 0 {
                    try check()
                }
                if let tag = lexer.consume(byte, at: row.lower + offset, prefix: originalPrefix) {
                    guard tags.count < 65_536 else {
                        throw NateError.message("单个物理行的完整标签证据超过 65536 项。")
                    }
                    tags.append(tag)
                    if !targets.isEmpty, tag.kind == .close, tag.range.lower >= row.lower {
                        closedByStart[tag.range.lower] = tag.name
                    }
                }
            }
            var suffixes: [ByteRange: [UInt8]] = [:]
            var suffix = 0
            for target in targets.sorted(by: { $0.upper < $1.upper }) {
                try check()
                guard target.upper < row.upper else {
                    break
                }
                suffix = try followingSpace(
                    bytes,
                    from: max(suffix, target.upper - row.lower),
                    limit: row.count,
                    check: check
                )
                suffixes[target] = closedByStart[row.lower + suffix]
            }
            var index = 0
            var offset = 0
            var lastContent = row.lower - 1
            var tail: Tail?
            for target in targets.sorted(by: { $0.lower < $1.lower }) {
                try check()
                let lower = min(target.lower, row.upper)
                while index < tags.count, tags[index].range.upper <= lower {
                    try consume(tags[index], bytes: bytes, row: row, scope: &scope, tail: &tail, check: check)
                    index += 1
                }
                while offset < lower - row.lower {
                    if offset & 255 == 0 {
                        try check()
                    }
                    if !isSpace(bytes[offset]) {
                        lastContent = row.lower + offset
                    }
                    offset += 1
                }
                let following = suffixes[target]
                if let tail, tail.end - 1 == lastContent {
                    let source = try prefix(for: tail.prefix)
                    if tail.kind == .open {
                        output[target] =
                            following == tail.name
                            ? .expandAlignedPair(prefix: source) : .align(prefix: source, levels: 1)
                    }
                    else {
                        let next = try following.flatMap {
                            try scope.matching($0, check: check)?.frame.prefix
                        }
                        output[target] = .align(
                            prefix: try next.map { try prefix(for: $0) } ?? source,
                            levels: 0
                        )
                    }
                }
                else if lower <= originalPrefix.upper, let following,
                    let matching = try scope.matching(following, check: check)
                {
                    output[target] = .align(prefix: try prefix(for: matching.frame.prefix), levels: 0)
                }
                else {
                    output[target] = .inherit
                }
            }
            while index < tags.count {
                try consume(tags[index], bytes: bytes, row: row, scope: &scope, tail: &tail, check: check)
                index += 1
            }
        }
        try check()
        return output
    }

    /// 业务作用：消费真实标签，并保留仍能影响本物理行换行的开端或连续行首闭合。
    /// 参数说明:
    /// - tag: 当前固定正文中已确认的完整标签。
    /// - bytes: 当前物理行的原字节。
    /// - row: 不含物理换行的真实行范围。
    /// - scope: 已确认的跨行结构作用域。
    /// - tail: 最近有效的同行开端或一组行首闭合中的最后一项。
    /// - check: 当前事务的共同继续资格。
    /// 返回：更新结构和同行证据；取消或容量超限时停止整个事务。
    private static func consume(
        _ tag: MarkupIndentationTag,
        bytes: [UInt8],
        row: ByteRange,
        scope: inout MarkupIndentationScope,
        tail: inout Tail?,
        check: () throws -> Void
    ) throws {
        try check()
        switch tag.kind {
        case .open, .empty:
            try scope.open(tag, check: check)
            tail =
                tag.kind == .open
                ? Tail(kind: .open, end: tag.range.upper, prefix: tag.prefix, name: tag.name) : nil
        case .close:
            guard let matching = try scope.close(tag, check: check) else {
                tail = nil
                return
            }
            let leading: Bool
            if tag.range.lower == tag.prefix.upper {
                leading = true
            }
            else if let previous = tail, previous.kind == .close, previous.end >= row.lower {
                let start = try followingSpace(
                    bytes,
                    from: previous.end - row.lower,
                    limit: tag.range.lower - row.lower,
                    check: check
                )
                leading = row.lower + start == tag.range.lower
            }
            else {
                leading = false
            }
            tail =
                leading
                ? Tail(kind: .close, end: tag.range.upper, prefix: matching.prefix, name: tag.name) : nil
        }
    }

    /// 业务作用：沿同一物理行跨越真实缩进字节，保持大量光标之间的扫描工作有界。
    /// 参数说明:
    /// - bytes: 当前物理行的原始字节。
    /// - start: 本次可继续读取的起始下标。
    /// - limit: 不得跨越的真实行内端点。
    /// - check: 当前编辑的继续资格。
    /// 返回：第一个正文位置或指定边界；取消时拒绝使用不完整的后继。
    private static func followingSpace(
        _ bytes: [UInt8],
        from start: Int,
        limit: Int,
        check: () throws -> Void
    ) throws -> Int {
        var index = start
        while index < limit, isSpace(bytes[index]) {
            if index & 255 == 0 {
                try check()
            }
            index += 1
        }
        return index
    }

    /// 业务作用：缩进只继承用户原有 ASCII 空白，其它字符保留正文身份。
    /// 参数说明:
    /// - byte: 当前物理行中的原字节。
    /// 返回：空格或真实 Tab 时成立。
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9
    }
}
