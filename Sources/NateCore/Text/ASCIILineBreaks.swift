import CoreFoundation
import Foundation

struct ASCIILineBreaks: Sendable {
    let range: ByteRange
    private let pageEnds: [Int]
    private static let pageBytes = 32_768
    private static let boundarySearchBytes = 8192

    /// 业务作用：把超长可打印 ASCII 断行分成原生分词器可完整读取的页，页边不会切断数值或标点语境。
    /// 参数说明:
    /// - text: 已提交的不可变正文。
    /// - range: 由调用者确认完全属于可打印 ASCII 的同一物理行。
    /// - deadline: 本次完整断行工作共享的截止。
    /// 返回：所有页边均已确认时提供索引，缺少可靠页边时不发布部分证据。
    init?(text: PieceTree, range: ByteRange, deadline: ContinuousClock.Instant) throws {
        var ends: [Int] = []
        var lower = range.lower
        while lower < range.upper {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("超长标点断行的分页超过共同截止。")
            }
            let maximum = min(lower + Self.pageBytes, range.upper)
            if maximum == range.upper {
                ends.append(maximum)
                break
            }
            let start = maximum - Self.boundarySearchBytes
            let sample = text.bytes(in: ByteRange(start, maximum + 1))
            guard let relative = Self.stableBoundary(in: sample) else {
                return nil
            }
            lower = start + relative
            ends.append(lower)
        }
        self.range = range
        pageEnds = ends
    }

    /// 业务作用：只在字母数字、普通空格及下一字母数字之间结束分词页，保留两侧原始断行语义。
    /// 参数说明:
    /// - sample: 当前后段内含少量后继正文的可打印 ASCII 字节。
    /// 返回：从样本起点计的真实分页端点；缺少完整周边证据时为空。
    private static func stableBoundary(in sample: [UInt8]) -> Int? {
        for current in stride(from: sample.count - 1, through: 2, by: -1)
        where sample[current - 1] == 32 && PieceNode.isASCIIAlphanumeric(sample[current]) {
            var previous = current - 1
            while previous > 0, sample[previous] == 32 {
                previous -= 1
            }
            if PieceNode.isASCIIAlphanumeric(sample[previous]) {
                return current
            }
        }
        return nil
    }

    /// 业务作用：命中或导航仅载入给定字节所处的完整已证分页。
    /// 参数说明:
    /// - offset: 当前完整逻辑行内的实际 UTF-8 坐标。
    /// 返回：覆盖坐标的完整原始页；跨范围时为空。
    private func page(covering offset: Int) -> ByteRange? {
        guard (range.lower...range.upper).contains(offset), !pageEnds.isEmpty else {
            return nil
        }
        var lower = 0
        var upper = pageEnds.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pageEnds[middle] < offset {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        let start = lower == 0 ? range.lower : pageEnds[lower - 1]
        return ByteRange(start, pageEnds[lower])
    }

    struct Cursor {
        private let source: ASCIILineBreaks
        private let text: PieceTree
        private var page: ByteRange?
        private var boundaries: [Int] = []

        /// 业务作用：离线断行和视口查询沿同一原始分页逐页读取原生边界。
        /// 参数说明:
        /// - source: 同一不可变正文已经确定的完整安全分页。
        /// - text: 产生分页的实际原文。
        /// 返回：可以按需复验扫描坐标的有限缓存。
        init(source: ASCIILineBreaks, text: PieceTree) {
            self.source = source
            self.text = text
        }

        /// 业务作用：词间断行使用分词器确认的原始边界；实际容器不能容纳整词时由调用者强制断行。
        /// 参数说明:
        /// - offset: 已确认的 ASCII 原字节位置。
        /// 返回：不越过该点的一个确定可断行边界；原生范围不一致时终止准备。
        mutating func boundary(atOrBefore offset: Int) throws -> Int {
            if let page, (page.lower...page.upper).contains(offset) {
                return boundaryInPage(atOrBefore: offset)
            }
            guard let page = source.page(covering: offset) else {
                throw NateError.message("超长 ASCII 标点断行缺少实际分页坐标。")
            }
            let raw = text.text(in: page)
            guard
                let tokenizer = CFStringTokenizerCreate(
                    nil,
                    raw as CFString,
                    CFRange(location: 0, length: page.count),
                    CFOptionFlags(kCFStringTokenizerUnitLineBreak),
                    nil
                )
            else {
                throw NateError.message("当前系统无法提供 ASCII 标点的原生断行。")
            }
            var accepted = [page.lower]
            var consumed = 0
            while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                let span = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard span.location == consumed, span.length > 0, span.length <= page.count - consumed else {
                    throw NateError.message("ASCII 标点断行的原生范围与源正文不一致。")
                }
                consumed += span.length
                accepted.append(page.lower + consumed)
            }
            // 原生分词结果必须完整覆盖一页，缺少后继边界不能当成页面原有的可断行位置。
            guard consumed == page.count else {
                throw NateError.message("ASCII 标点断行的原生分页不完整。")
            }
            self.page = page
            boundaries = accepted
            return boundaryInPage(atOrBefore: offset)
        }

        /// 业务作用：在已完整确认的原生分页中定位最近断点，无需重扫此前正文。
        /// 参数说明:
        /// - offset: 落在当前页内的有效原字节偏移。
        /// 返回：同一完整页内不晚于该偏移的最后可断行边界。
        private func boundaryInPage(atOrBefore offset: Int) -> Int {
            var lower = 0
            var upper = boundaries.count
            while lower + 1 < upper {
                let middle = lower + (upper - lower) / 2
                if boundaries[middle] <= offset {
                    lower = middle
                }
                else {
                    upper = middle
                }
            }
            return boundaries[lower]
        }
    }
}
