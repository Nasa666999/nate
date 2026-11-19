import Foundation

public struct PrintSourcePlan: Sendable {
    public let text: PieceTree
    public let range: ByteRange
    public let sections: [ByteRange]
    public let formFeeds: [Int]

    /// 业务作用：以固定原文字节规划强制分页，不因屏幕折叠、隐藏或软换行漏掉正文。
    /// 参数说明:
    /// - text: 当前作业唯一的不可变正文树。
    /// - range: 明确全文或连续选择的原范围，省略时为全文。
    /// - formFeedPageBreaks: 是否为每个 FF 建立强制分页边界。
    /// - permit: 整次范围枚举仍有效的资格。
    /// 返回：连续覆盖完整原范围的章节及实际 FF 位置；超时、非法边界、超过十万处分页或取消整体失败。
    public init(
        text: PieceTree,
        range: ByteRange? = nil,
        formFeedPageBreaks: Bool,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = range ?? ByteRange(0, text.byteCount)
        guard range.lower >= 0, range.upper >= range.lower,
            text.isBoundary(range.lower), text.isBoundary(range.upper)
        else {
            throw NateError.invalidRange
        }
        // 选区打印不能把半个 CRLF 解释成独立行，否则原行号与实际分页会采用不同的正文边界。
        for point in [range.lower, range.upper] {
            guard !(text.byte(at: point - 1) == 13 && text.byte(at: point) == 10) else {
                throw NateError.message("打印范围不能切开 CRLF。")
            }
        }
        try Self.check(deadline: deadline, permit: permit)
        self.text = text
        self.range = range
        guard formFeedPageBreaks else {
            sections = [range]
            formFeeds = []
            return
        }
        var sections: [ByteRange] = [], feeds: [Int] = []
        var offset = range.lower, start = range.lower
        try text.slicing(range).forEachChunk(maximumBytes: 65_536) {
            chunk in
            try Self.check(deadline: deadline, permit: permit)
            for (index, byte) in chunk.bytes().enumerated() where byte == 12 {
                guard feeds.count < 100_000 else {
                    throw NateError.message("打印强制分页超过十万处，未采用部分分页。")
                }
                let position = offset + index
                let row = text.lineNumber(at: position)
                let body = text.lineRange(row, includeEnding: false)
                let boundary: Int
                if position == body.lower {
                    boundary = position
                }
                else if position + 1 == body.upper {
                    // 行尾 FF 连同当前真实结束符留在旧页，CRLF 始终作为不可拆分的原文单位。
                    boundary = min(range.upper, text.lineRange(row).upper)
                }
                else {
                    boundary = position + 1
                }
                guard boundary >= start, boundary <= range.upper else {
                    throw NateError.invalidRange
                }
                sections.append(ByteRange(start, boundary))
                feeds.append(position)
                start = boundary
            }
            offset += chunk.byteCount
        }
        if start < range.upper || sections.isEmpty {
            sections.append(ByteRange(start, range.upper))
        }
        try Self.check(deadline: deadline, permit: permit)
        self.sections = sections
        formFeeds = feeds
    }

    /// 业务作用：分页枚举在固定分块边界响应取消，不把完整源范围替换成已经处理的前缀。
    /// 参数说明:
    /// - deadline: 原始五秒截止时间。
    /// - permit: 原调用仍有效的资格。
    /// 返回：有效时继续；取消或超时失败。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("打印分页源枚举超过五秒预算。")
        }
    }
}
