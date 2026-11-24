import Foundation

enum LineIndentationEdits {
    static let maximumLines = 100_000

    /// 业务作用：明确选区覆盖的实际物理行，下一行行首作为末端时不扩大编辑范围。
    /// 参数说明:
    /// - range: 已确认的真实选区范围或空光标。
    /// - text: 与选区来自同一快照的正文。
    /// 返回：至少一条实际行，空光标只涉及所属行。
    static func rows(for range: ByteRange, in text: PieceTree) -> ClosedRange<Int> {
        let first = text.lineNumber(at: range.lower)
        let last = text.lineNumber(at: range.upper)
        let end = first < last && text.lineStart(last) == range.upper ? last - 1 : last
        return first...end
    }

    /// 业务作用：增加一级时只在行首插入当前配置的空白，原有缩进字节由正文继续保留。
    /// 参数说明:
    /// - settings: 当前语言明确指定的宽度及写入方式。
    /// 返回：完整一级 ASCII 空格或一个真实 Tab。
    static func unit(_ settings: TabSettings) -> String {
        settings.useSpaces ? String(repeating: " ", count: settings.width) : "\t"
    }

    /// 业务作用：从行首移除一个完整停靠级别，保留该级别以外的混合缩进和原正文。
    /// 参数说明:
    /// - row: 当前物理行或已经确认的前导空白范围。
    /// - text: 与该行来自同一快照的原始正文。
    /// - width: 当前语言完整的 Tab 列宽。
    /// 返回：只删除首个停靠位之前的原字节；没有缩进时为空。
    static func removal(in row: ByteRange, text: PieceTree, width: Int) -> TextEdit? {
        var end = row.lower
        // 首级里的 Tab 恰好到达该级终点，直接移除首级后无需重写任何剩余空白。
        while end < row.upper, end - row.lower < width, let byte = text.byte(at: end), byte == 32 || byte == 9
        {
            end += 1
            if byte == 9 {
                break
            }
        }
        return end == row.lower ? nil : TextEdit(ByteRange(row.lower, end), "")
    }
}
