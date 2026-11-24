import NateCore

struct DocumentMapOverview: Sendable {
    static let maximumRows = 320
    static let maximumColumns = 100
    let lineCount: Int
    let rows: [[Range<Int>]]

    /// 业务作用：按逻辑行区间取少量实际原文字节，生成可定位的整份文档概览。
    /// 参数说明:
    /// - tree: 已确认正文的不可变分块树。
    /// - tabWidth: 来源编辑视图正在使用的列宽。
    /// 返回：每行距离和空白分布的有界摘要；取消或超过共同截止时间时整份舍弃。
    static func make(tree: PieceTree, tabWidth: Int) -> DocumentMapOverview? {
        let count = max(1, tree.lineCount)
        let rows = min(count, maximumRows)
        let block = count / rows
        let remainder = count % rows
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var shapes: [[Range<Int>]] = []
        shapes.reserveCapacity(rows)
        for row in 0..<rows {
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                return nil
            }
            let start = row * block + (row * remainder) / rows
            let end = (row + 1) * block + ((row + 1) * remainder) / rows
            let middle = start + (end - start - 1) / 2
            var selected: [Range<Int>] = []
            var selectedWidth = 0
            // 大文档的一个预览行可代表多行，分别取首、中、尾以保留区间内可见的正文形态。
            let samples = end - start > 2 ? [start, middle, end - 1] : Array(start..<end)
            for line in samples {
                let units = outline(tree: tree, line: line, tabWidth: max(1, min(32, tabWidth)))
                let width = units.reduce(0) { $0 + $1.count }
                if width > selectedWidth {
                    selected = units
                    selectedWidth = width
                }
            }
            shapes.append(selected)
        }
        return DocumentMapOverview(lineCount: count, rows: shapes)
    }

    /// 业务作用：只检查单行开头有限字节，为实际文字和中间空白保留不同位置。
    /// 参数说明:
    /// - tree: 固定正文。
    /// - line: 实际逻辑行位置。
    /// - tabWidth: 已限制范围的来源 Tab 列宽。
    /// 返回：按顺序的非空白示意区间，至多八段，不申请原行的完整字形布局。
    private static func outline(tree: PieceTree, line: Int, tabWidth: Int) -> [Range<Int>] {
        let raw = tree.lineRange(line, includeEnding: false)
        let length = min(raw.count, 300)
        let bytes = tree.bytes(in: ByteRange(raw.lower, raw.lower + length))
        var columns = 0
        var start: Int?
        var segments: [Range<Int>] = []
        for byte in bytes {
            guard columns < maximumColumns, segments.count < 8 else {
                break
            }
            if byte == 9 || byte == 32 {
                if let first = start {
                    segments.append(first..<columns)
                    start = nil
                }
                columns += byte == 9 ? tabWidth - columns % tabWidth : 1
            }
            else if byte & 0xC0 != 0x80 {
                start = start ?? columns
                columns += 1
            }
        }
        if let start {
            segments.append(start..<columns)
        }
        return segments
    }
}
