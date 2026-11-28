import Foundation

public enum HanLogicalColumns: Sendable {
    case plain(PlainHanLine)
    case tabbed(HanTabColumns)
    case narrow(PlainNarrowUnicodeLine)
    case combining(PlainCombiningLine)

    /// 业务作用：逻辑列索引只绑定真实物理行的正文区间。
    /// 参数说明: 无。
    /// 返回：当前测量的完整逻辑行原字节范围。
    var range: ByteRange {
        switch self {
        case .plain(let value): value.range
        case .tabbed(let value): value.range
        case .narrow(let value): value.range
        case .combining(let value): value.range
        }
    }

    /// 业务作用：Tab、Shift+Tab 和语义宏只复用同一正文及必要的实际制表宽度。
    /// 参数说明:
    /// - text: 当前输入的不可变原字节树。
    /// - width: 当前语言的真实 Tab 间隔。
    /// 返回：已选证据与当前原文一致时为真；无 Tab 原文独立于制表宽度。
    func matches(_ text: PieceTree, width: Int) -> Bool {
        switch self {
        case .plain(let value): value.matches(text)
        case .tabbed(let value): value.matches(text, tabWidth: width)
        case .narrow(let value): value.matches(text)
        case .combining(let value): value.matches(text, tabWidth: width)
        }
    }

    /// 业务作用：从原位置计算真实逻辑制表列，各原生字形宽度不进入编辑列数。
    /// 参数说明:
    /// - offset: 相对当前完整行首的真实字节端点。
    /// 返回：相应列数；非法字节端点为空。
    func column(at offset: Int) -> Int? {
        guard (0...range.count).contains(offset) else {
            return nil
        }
        switch self {
        case .plain(let value):
            return value.character(atByte: value.range.lower + offset)
        case .tabbed(let value):
            return value.column(at: offset)
        case .narrow(let value):
            return value.character(atByte: value.range.lower + offset)
        case .combining(let value):
            return value.cell(atByte: value.range.lower + offset)
        }
    }

    /// 业务作用：原选择可回到前一个完整停靠端点，Tab 内不能伪造 UTF-8 字节位置。
    /// 参数说明:
    /// - column: 相对逻辑行首的明确编辑列。
    /// 返回：不越过当前列的相对原字节端点；行外为空。
    func offset(atOrBefore column: Int) -> Int? {
        switch self {
        case .plain(let value):
            return value.byte(at: column).map { $0 - value.range.lower }
        case .tabbed(let value):
            return value.offset(atOrBefore: column)
        case .narrow(let value):
            return value.byte(at: column).map { $0 - value.range.lower }
        case .combining(let value):
            return value.character(atCell: column).flatMap { value.byte(at: $0) }.map {
                $0 - value.range.lower
            }
        }
    }
}
