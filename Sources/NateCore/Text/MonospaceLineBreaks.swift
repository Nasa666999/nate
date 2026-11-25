import CoreFoundation
import Foundation

struct MonospaceLineBreaks: Sendable {
    let range: ByteRange
    private let pageEnds: [Int]
    private static let pageBytes = 32_768
    private static let boundarySearchBytes = 8192

    /// 业务作用：把已确认字形的长行交给原生分词器逐页解释，页边保留数值与标点语境。
    /// 参数说明:
    /// - text: 已提交的不可变正文。
    /// - range: 已由调用者确认字符组成的同一物理行。
    /// - allowsNarrowLetters: 正文已完整确认可含独立的两字节窄字母时为真。
    /// - allowsFullwidth: 同一正文已确认可含基本统一汉字和指定的全角标点时为真。
    /// - deadline: 本次完整断行工作共享的截止。
    /// 返回：所有页边均已确认时提供索引，缺少可靠页边时不发布部分证据。
    init?(
        text: PieceTree,
        range: ByteRange,
        allowsNarrowLetters: Bool,
        allowsFullwidth: Bool = false,
        deadline: ContinuousClock.Instant
    ) throws {
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
            guard
                let relative = Self.stableBoundary(
                    in: sample,
                    allowsNarrowLetters: allowsNarrowLetters,
                    allowsFullwidth: allowsFullwidth
                )
            else {
                return nil
            }
            lower = start + relative
            ends.append(lower)
        }
        self.range = range
        pageEnds = ends
    }

    /// 业务作用：只在词间完整空白或相邻基本统一汉字之间分开分词页，保留两侧原始断行语义。
    /// 参数说明:
    /// - sample: 当前页后段与少量后继的原始字节。
    /// - allowsNarrowLetters: 范围已由同一原文确认两字节窄字母时为真。
    /// - allowsFullwidth: 范围允许确实成对相邻的基本统一汉字作为页边时为真。
    /// 返回：从样本起点计的真实分页端点；缺少完整周边证据时为空。
    private static func stableBoundary(
        in sample: [UInt8],
        allowsNarrowLetters: Bool,
        allowsFullwidth: Bool
    ) -> Int? {
        for current in stride(from: sample.count - 1, through: 2, by: -1) {
            if allowsFullwidth, current >= 3, current + 1 < sample.count,
                isUnifiedIdeograph(sample[current - 3], second: sample[current - 2]),
                isUnifiedIdeograph(sample[current], second: sample[current + 1])
            {
                return current
            }
            guard (sample[current - 1] == 32 || sample[current - 1] == 9),
                isWordStart(sample[current], allowsNarrowLetters: allowsNarrowLetters)
            else {
                continue
            }
            var previous = current - 1
            while previous > 0, sample[previous] == 32 || sample[previous] == 9 {
                previous -= 1
            }
            if allowsNarrowLetters, (128...191).contains(sample[previous]), previous > 0 {
                // 样本可能从 UTF-8 中间开始，只有可见完整前驱才能证明分页端点。
                previous -= 1
            }
            if isWordStart(sample[previous], allowsNarrowLetters: allowsNarrowLetters) {
                return current
            }
        }
        return nil
    }

    /// 业务作用：用已验证 UTF-8 的前两个字节区分基本统一汉字与全角标点，页边不会落在标量内部。
    /// 参数说明:
    /// - first: 候选标量的首字节。
    /// - second: 候选标量的后继字节。
    /// 返回：完整三字节标量属于 U+4E00 至 U+9FFF 时为真。
    private static func isUnifiedIdeograph(_ first: UInt8, second: UInt8) -> Bool {
        (229...233).contains(first) || first == 228 && second >= 184
    }

    /// 业务作用：分页仅在普通字母数字通道重启，避免上下文字符跨越页边改变断行。
    /// 参数说明:
    /// - byte: 已知在完整原文中带有效字符身份的候选首字节。
    /// - allowsNarrowLetters: 窄字母原文已经预验时为真。
    /// 返回：合法 ASCII 字母数字或同源两字节窄字母首字节为真。
    private static func isWordStart(_ byte: UInt8, allowsNarrowLetters: Bool) -> Bool {
        PieceNode.isASCIIAlphanumeric(byte) || allowsNarrowLetters && (194...223).contains(byte)
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
        private let source: MonospaceLineBreaks
        private let text: PieceTree
        private var page: ByteRange?
        private var boundaries: [Int] = []

        /// 业务作用：离线断行和视口查询沿同一原始分页逐页读取原生边界。
        /// 参数说明:
        /// - source: 同一不可变正文已经确定的完整安全分页。
        /// - text: 产生分页的实际原文。
        /// 返回：可以按需复验扫描坐标的有限缓存。
        init(source: MonospaceLineBreaks, text: PieceTree) {
            self.source = source
            self.text = text
        }

        /// 业务作用：词间断行使用分词器确认的原始边界；实际容器不能容纳整词时由调用者强制断行。
        /// 参数说明:
        /// - offset: 已确认的完整原字节端点。
        /// 返回：不越过该点的一个确定可断行边界；原生范围不一致时终止准备。
        mutating func boundary(atOrBefore offset: Int) throws -> Int {
            if let page, (page.lower...page.upper).contains(offset) {
                return boundaryInPage(atOrBefore: offset)
            }
            guard let page = source.page(covering: offset) else {
                throw NateError.message("超长等宽标点断行缺少实际分页坐标。")
            }
            let raw = text.text(in: page)
            let unitCount = raw.utf16.count
            var byteOffsets: [Int] = []
            if unitCount != page.count {
                // 预验保证每字符只占一个 UTF-16 单元，分词器范围仍须还原为准确的 UTF-8 端点。
                byteOffsets.reserveCapacity(unitCount + 1)
                for (offset, byte) in raw.utf8.enumerated() where byte & 192 != 128 {
                    byteOffsets.append(offset)
                }
                guard byteOffsets.count == unitCount else {
                    throw NateError.message("等宽标点分页的原字符坐标不一致。")
                }
                byteOffsets.append(page.count)
            }
            guard
                let tokenizer = CFStringTokenizerCreate(
                    nil,
                    raw as CFString,
                    CFRange(location: 0, length: unitCount),
                    CFOptionFlags(kCFStringTokenizerUnitLineBreak),
                    nil
                )
            else {
                throw NateError.message("当前系统无法提供等宽标点的原生断行。")
            }
            var accepted = [page.lower]
            var consumed = 0
            while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                let span = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard span.location == consumed, span.length > 0, span.length <= unitCount - consumed else {
                    throw NateError.message("等宽标点断行的原生范围与源正文不一致。")
                }
                consumed += span.length
                accepted.append(page.lower + (byteOffsets.isEmpty ? consumed : byteOffsets[consumed]))
            }
            // 原生分词结果必须完整覆盖一页，缺少后继边界不能当成页面原有的可断行位置。
            guard consumed == unitCount else {
                throw NateError.message("等宽标点断行的原生分页不完整。")
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
