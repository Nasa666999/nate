import Foundation
import NateCore
import NateSearch
import NateUI

enum StyleMarkPlanning {
    /// 业务作用：五组样式只读取实际选区或有界当前词，所有匹配采用独立的字面大小写与整词选项。
    /// 参数说明:
    /// - snapshot: 同时固定正文与颜色状态的输入。
    /// - selections: 当前实际视图中的完整选区。
    /// - style: 本次添加的持久颜色组。
    /// - all: 是否在全文标记所选文本的所有字面匹配。
    /// - preferences: 独立于查找窗口的样式匹配偏好。
    /// - permit: 本次后台操作仍有效的取消权限。
    /// 返回：保留旧样式的完整标记计划、实际匹配数和无法无损表示数；无词、超限或非法范围整体失败。
    static func prepare(
        snapshot: DocumentMarkSnapshot,
        selections: [TextSelection],
        style: DocumentMarkStyle,
        all: Bool,
        preferences: StyleMarkPreferences,
        permit: @escaping @Sendable () -> Bool
    ) throws -> (plan: PreparedDocumentMarks, matched: Int, unmapped: Int) {
        guard permit() else {
            throw CancellationError()
        }
        guard !selections.isEmpty, selections.count <= 100_000 else {
            throw NateError.message("请先选择正文，颜色标记一次最多使用十万个选区。")
        }
        let tree = snapshot.document.text
        let ranges: [ByteRange]
        let matched: Int
        let unmapped: Int
        if all {
            guard selections.count == 1, let selection = selections.first, selection.virtualColumn == 0 else {
                throw NateError.message("标记全部匹配需要一个实际选区或一个光标；多选可使用“仅标记选区”。")
            }
            let range = try sourceRange(selection, tree: tree)
            // 完整表达式必须先满足容量与字符边界，不能截断长选区后标记另一段文本。
            guard range.count <= 1_048_576 else {
                throw NateError.message("样式匹配文本超过 1 MiB，原样式保留。")
            }
            var options = SearchOptions()
            options.query = tree.text(in: range)
            options.caseSensitive = preferences.caseSensitive
            options.wholeWord = preferences.wholeWord
            let result = try SearchEngine.find(in: snapshot.document, options: options, permit: permit)
            ranges = result.hits.compactMap(\.range)
            matched = result.hits.count
            unmapped = matched - ranges.count
        }
        else {
            let selected = selections.map(\.range).filter {
                !$0.isEmpty
            }
            if selected.isEmpty {
                guard selections.count == 1, let selection = selections.first, selection.virtualColumn == 0
                else {
                    throw NateError.message("多光标请先选中实际正文，再添加颜色样式。")
                }
                ranges = [try sourceRange(selection, tree: tree)]
            }
            else {
                ranges = selected
            }
            matched = ranges.count
            unmapped = 0
        }
        let plan = try PreparedDocumentMarks(
            snapshot: snapshot,
            ranges: ranges,
            style: style,
            append: true,
            permit: permit
        )
        return (plan, matched, unmapped)
    }

    /// 业务作用：没有选区时使用光标所在完整词，明确选区按原文保留，不改变实际光标或选区。
    /// 参数说明:
    /// - selection: 当前视图中的单个真实选区或光标。
    /// - tree: 该选区所属固定正文。
    /// 返回：完整选区或至多 262144 标量的当前词；非词位置、边界非法或超限明确失败。
    private static func sourceRange(_ selection: TextSelection, tree: PieceTree) throws -> ByteRange {
        let range = selection.range
        guard tree.isBoundary(range.lower), tree.isBoundary(range.upper) else {
            throw NateError.invalidRange
        }
        if !range.isEmpty {
            return range
        }
        switch tree.wordSelection(at: selection.head, maximumScalars: 262_144) {
        case .word(let word): return word
        case .noWord: throw NateError.message("当前位置没有可标记的单词，请先选择正文。")
        case .exceedsLimit: throw NateError.message("当前词超过 262144 个标量，原样式保留；可选择较短正文。")
        }
    }
}
