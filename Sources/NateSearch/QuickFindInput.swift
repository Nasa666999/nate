import Foundation
import NateCore

public struct QuickFindInput: Sendable {
    public let query: String
    public let selection: ByteRange
    public let expandedWord: Bool

    /// 业务作用：快捷搜索读取单个实际选区或完整光标词，更新当前条件与临时搜索使用同一原文边界。
    /// 参数说明:
    /// - text: 当前视图所属的不可变正文。
    /// - selections: 真实视图选区，多选与虚拟列不能缩成一个查询。
    /// - fillLimit: 更新查找条件时使用的标量上限；临时搜索为空，仍受 1 MiB 表达式与完整词预算约束。
    /// 返回：完整字面原文与导航起点，不改变选区；非法范围、超限、无选区且无光标词时整体失败。
    public init(text: PieceTree, selections: [TextSelection], fillLimit: Int?) throws {
        if let fillLimit {
            guard (1...262_144).contains(fillLimit) else {
                throw NateError.message("快捷搜索填入上限须为 1–262144 个标量。")
            }
        }
        guard selections.count == 1, let selected = selections.first, selected.virtualColumn == 0 else {
            throw NateError.message("快捷搜索需要一个真实选区或光标，不支持多选与虚拟列。")
        }
        guard text.isBoundary(selected.anchor), text.isBoundary(selected.head) else {
            throw NateError.invalidRange
        }
        let range: ByteRange
        if selected.range.isEmpty {
            switch text.wordSelection(at: selected.head, maximumScalars: fillLimit ?? 262_144) {
            case .word(let word): range = word
            case .noWord: throw NateError.message("当前没有选中文本或完整光标词。")
            case .exceedsLimit:
                throw NateError.message("完整光标词超过快捷搜索字符上限，未截断原文。")
            }
        }
        else {
            range = selected.range
        }
        // 先检查范围与字符预算，再建立 String，巨型选区不能为了反馈上限而展开全文。
        guard range.count <= 1_048_576 else {
            throw NateError.message("快捷搜索原文超过 1 MiB，未截断查询。")
        }
        if let fillLimit {
            guard try text.boundedScalarCount(in: range, limit: fillLimit + 1) <= fillLimit else {
                throw NateError.message("选区超过查找填入字符上限，当前查询与历史保留。")
            }
        }
        query = text.text(in: range)
        selection = range
        expandedWord = selected.range.isEmpty
    }
}
