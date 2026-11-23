import Foundation

struct SortableLine {
    let body: ByteRange
    let ending: ByteRange
    let endingKind: UInt8
}

enum SortLineTable {
    /// 业务作用：按行数选择持久化索引或顺序分块，完整建立正文与结束符边界，避免大量行重复定位同一叶片。
    /// 参数说明:
    /// - text: 本次排序固定的不可变正文。
    /// - range: 首行至末行的完整原字节范围。
    /// - expectedCount: 已由选择权限确认的一至十万行，包含明确选中的末尾空行。
    /// - budget: 取键、行序与事务准备共同的取消、权限和三十秒截止。
    /// 返回：完整行表，临时原字节分块至多 64 KiB；字节边界、容量、行数或执行资格不足时整份拒绝。
    static func collect(
        in text: PieceTree,
        range: ByteRange,
        expectedCount: Int,
        budget: LineSortBudget
    ) throws -> [SortableLine] {
        try budget.check()
        // 行范围必须先取得完整权限，不能借截断范围拆开 CRLF 或隐式扩大排序目标。
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= text.byteCount,
            range.count <= 256 * 1024 * 1024, (1...100_000).contains(expectedCount),
            text.isBoundary(range.lower), text.isBoundary(range.upper),
            !(text.byte(at: range.lower - 1) == 13 && text.byte(at: range.lower) == 10),
            !(text.byte(at: range.upper - 1) == 13 && text.byte(at: range.upper) == 10)
        else {
            throw NateError.invalidRange
        }
        if expectedCount <= 64 {
            // 少量超长行直接使用持久化行索引，不能为了取得结束符而复制或扫描整条长行。
            let first = text.lineNumber(at: range.lower)
            guard expectedCount <= text.lineCount - first else {
                throw NateError.invalidRange
            }
            var output: [SortableLine] = []
            for line in first..<(first + expectedCount) {
                try budget.check()
                let full = text.lineRange(line)
                let body = text.lineRange(line, includeEnding: false)
                guard full.lower >= range.lower, full.upper <= range.upper else {
                    throw NateError.invalidRange
                }
                let ending = ByteRange(body.upper, full.upper)
                let bytes = text.bytes(in: ending)
                output.append(
                    SortableLine(
                        body: body,
                        ending: ending,
                        endingKind: bytes.isEmpty ? 0 : bytes == [10] ? 1 : bytes == [13, 10] ? 2 : 3
                    )
                )
            }
            try budget.check()
            guard output.first?.body.lower == range.lower, output.last?.ending.upper == range.upper else {
                throw NateError.invalidRange
            }
            return output
        }
        var output: [SortableLine] = []
        output.reserveCapacity(expectedCount)
        var start = range.lower
        var offset = range.lower
        var pendingCR: Int?
        let finish = { (bodyEnd: Int, end: Int, kind: UInt8) throws in
            try budget.check()
            guard output.count < expectedCount else {
                throw NateError.invalidRange
            }
            output.append(
                SortableLine(
                    body: ByteRange(start, bodyEnd),
                    ending: ByteRange(bodyEnd, end),
                    endingKind: kind
                )
            )
            start = end
        }
        try text.slicing(range).forEachChunk(maximumBytes: 65_536) { chunk in
            for byte in chunk.bytes() {
                if (offset - range.lower).isMultiple(of: 4096) {
                    try budget.check()
                }
                if let cr = pendingCR {
                    pendingCR = nil
                    if byte == 10 {
                        try finish(cr, offset + 1, 2)
                        offset += 1
                        continue
                    }
                    try finish(cr, offset, 3)
                }
                if byte == 13 {
                    // CR 的结束资格延迟一个原字节，跨共享分块的 CRLF 仍保留为同一个结束符。
                    pendingCR = offset
                }
                else if byte == 10 {
                    try finish(offset, offset + 1, 1)
                }
                offset += 1
            }
        }
        if let cr = pendingCR {
            try finish(cr, offset, 3)
        }
        if start < range.upper || output.count < expectedCount {
            try finish(range.upper, range.upper, 0)
        }
        // 全部行数与原范围一致之后才交付，取消或错误结束符不能留下可提交的部分行序。
        try budget.check()
        guard offset == range.upper, output.count == expectedCount else {
            throw NateError.invalidRange
        }
        return output
    }
}
