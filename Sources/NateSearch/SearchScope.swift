import Foundation
import NateCore

public struct ResolvedSearchScope: Sendable {
    public var range: ByteRange?
    public var options: SearchOptions
    public var description: String
}

public enum SearchScope {
    /// 业务作用：逐按钮确定范围，选区开关不是所有搜索动作的共同范围锁。
    /// 参数说明:
    /// - action: 当前具体按钮动作。
    /// - snapshot: 起始正文快照。
    /// - options: 用户原始选项。
    /// - selections: 同一快照的选区。
    /// 返回：实际范围及适用选项；无效选区明确拒绝，不扩大范围。
    public static func resolve(
        action: String,
        snapshot: DocumentSnapshot,
        options: SearchOptions,
        selections: [TextSelection]
    ) throws -> ResolvedSearchScope {
        var effective = options
        if ["open", "replaceOpen", "files", "replaceFiles", "projects", "replaceProjects"].contains(action) {
            effective.selectionOnly = false
            effective.backwards = false
            effective.wrap = true
            return ResolvedSearchScope(range: nil, options: effective, description: "各目标全文 · 正向")
        }
        if ["next", "previous", "replaceOne"].contains(action) {
            effective.selectionOnly = false
            return ResolvedSearchScope(range: nil, options: effective, description: "当前文档 · 方向导航")
        }
        if options.selectionOnly {
            guard selections.count == 1, let range = selections.first?.range, !range.isEmpty,
                snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper)
            else {
                throw NateError.message("选区内操作需要一个有效连续选区；多选和矩形选区不能使用此范围锁。")
            }
            return ResolvedSearchScope(
                range: range,
                options: effective,
                description: "仅原选区 · 字节 \(range.lower)–\(range.upper)"
            )
        }
        if action == "replaceAll" && !options.wrap {
            let selection: ByteRange
            if let state = snapshot.selectionState, state.selections == selections {
                selection = state.primary.selection.range
            }
            else {
                selection = selections.first?.range ?? ByteRange(0, 0)
            }
            let range =
                options.backwards
                ? ByteRange(0, selection.upper) : ByteRange(selection.lower, snapshot.text.byteCount)
            guard snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper) else {
                throw NateError.invalidRange
            }
            return ResolvedSearchScope(
                range: range,
                options: effective,
                description: "\(options.backwards ? "开头到选区终点" : "选区起点到末尾") · 字节 \(range.lower)–\(range.upper)"
            )
        }
        return ResolvedSearchScope(range: nil, options: effective, description: "当前文档全文")
    }
}
