import Foundation
import NateCore

extension TeXFolding {
    /// 业务作用：折叠控制词采用最多九十九个 ASCII 名称字节，原文字面不被执行。
    /// 参数说明:
    /// - offset: 已确认反斜杠的原字节位置。
    /// - tree: 当前完整不可变正文。
    /// - budget: 本轮完整折叠共用的预算。
    /// 返回：完整有界名称，非名称候选为空。
    static func command(at offset: Int, tree: PieceTree, budget: inout ANSILexingBudget) throws -> String {
        var bytes: [UInt8] = []
        for index in 1...99 {
            try budget.consume()
            let byte = tree.byte(at: offset + index) ?? 0
            if index == 1, [44, 58, 59, 37].contains(byte) {
                return String(decoding: [byte], as: UTF8.self)
            }
            guard byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 else {
                break
            }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 业务作用：成对环境与条件命令分别增加或减少层级，保留名称大小写与前缀规则。
    /// 参数说明:
    /// - name: 当前有界原始控制词。
    /// 返回：起始为一，结束为负一，其它命令为零。
    static func paired(_ name: String) -> Int {
        if ["end", "FoldStop", "maketitle", "protect", "fi"].contains(name)
            || name.hasPrefix("stop") || name.hasPrefix("Stop")
        {
            return -1
        }
        if ["begin", "FoldStart", "abstract", "unprotect", "title", "documentclass"].contains(name)
            || name.hasPrefix("start") || name.hasPrefix("Start") || name.hasPrefix("if")
        {
            return 1
        }
        return 0
    }

    /// 业务作用：章节与定义命令在后续同类首行前收束，不要求虚构结束命令。
    /// 参数说明:
    /// - name: 当前有界原始控制词。
    /// 返回：具有独立标题层级时为一，其它为零。
    static func unpaired(_ name: String) -> Int {
        [
            "part", "chapter", "section", "subsection", "subsubsection", "CJKfamily", "appendix",
            "Topic", "topic", "subject", "subsubject", "def", "gdef", "edef", "xdef", "framed",
            "frame", "foilhead", "overlays", "slide",
        ].contains(name) ? 1 : 0
    }

    /// 业务作用：明确折叠标记只按完整原字节匹配，部分标记不能创造隐藏区域。
    /// 参数说明:
    /// - marker: 固定 ASCII 标记。
    /// - offset: 当前原字节起点。
    /// - tree: 当前完整不可变正文。
    /// - budget: 本轮折叠的共同预算。
    /// 返回：标记字节全部匹配时为真。
    static func matches(_ marker: String, at offset: Int, tree: PieceTree, budget: inout ANSILexingBudget)
        throws -> Bool
    {
        for (index, byte) in marker.utf8.enumerated() {
            try budget.consume()
            guard tree.byte(at: offset + index) == byte else {
                return false
            }
        }
        return true
    }
}
