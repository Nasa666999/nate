import AppKit
import NateCore
import NateSearch
import NateUI

@MainActor
final class SearchNavigationEvidence {
    weak var buffer: DocumentBuffer?
    weak var editor: EditorView?
    let revision: UInt64
    let options: SearchOptions
    let selection: ByteRange

    /// 业务作用：保留已发布命中的继续证据，不延长关闭文档及视图的生命周期。
    /// 参数说明:
    /// - buffer: 命中所属的真实缓冲区对象。
    /// - editor: 接收命中的具体克隆视图。
    /// - options: 发布时的完整查找条件。
    /// - selection: 本次实际选中的匹配。
    /// 返回：同一对象、修订、条件与视图的短期导航证据。
    init(buffer: DocumentBuffer, editor: EditorView, options: SearchOptions, selection: ByteRange) {
        self.buffer = buffer
        self.editor = editor
        revision = buffer.revision
        self.options = options
        self.selection = selection
    }

    /// 业务作用：只有原空命中仍被原视图选中时才抑制起点空结果。
    /// 参数说明:
    /// - buffer: 本次请求的缓冲区。
    /// - editor: 本次请求所属视图。
    /// - options: 当前条件。
    /// - selection: 当前主选区。
    /// 返回：完整证据一致且确为零长度命中时为真。
    func continues(buffer: DocumentBuffer, editor: EditorView, options: SearchOptions, selection: ByteRange)
        -> Bool
    {
        self.buffer === buffer && self.editor === editor && revision == buffer.revision
            && self.options == options && self.selection == selection && selection.isEmpty
    }
}

extension ApplicationController {
    /// 业务作用：按焦点视图的真实起点导航或复验单次替换，发布前同时复验正文和视图位置。
    /// 参数说明:
    /// - action: 下一个、上一个或单次替换动作。
    /// - options: 用户当前完整条件。
    /// - afterReplacement: 是否保留刚完成的单次替换反馈。
    /// 返回：一个可见命中、单次原子替换或明确边界；迟到结果不移动新光标。
    func navigateSearch(_ action: String, options: SearchOptions, afterReplacement: Bool) {
        guard let document = active, let editor = mainWindow?.editor, editor.document === document.buffer
        else {
            return
        }
        let buffer = document.buffer
        let snapshot = buffer.snapshot
        let selections = editor.viewSelections
        let selection = selections.first?.range ?? ByteRange(0, 0)
        let continuing =
            searchNavigationEvidence?.continues(
                buffer: buffer,
                editor: editor,
                options: options,
                selection: selection
            ) ?? false
        searchNavigationEvidence = nil
        let generation = queryGeneration
        let navigationGeneration = searchNavigationGeneration
        searchTask = Task {
            [weak self, weak editor] in
            guard let self else {
                return
            }
            // 只收回本请求的句柄，迟到完成不能清除新查询仍在使用的取消入口。
            defer {
                if generation == self.queryGeneration {
                    self.searchTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let result =
                        try action == "replaceOne"
                        ? SearchEngine.selectedMatch(in: snapshot, options: options, selection: selection)
                        : SearchEngine.navigate(
                            in: snapshot,
                            options: options,
                            selection: selection,
                            previous: action == "previous",
                            continuingEmpty: continuing
                        )
                    let edits =
                        try action == "replaceOne"
                        ? SearchEngine.replacementPlan(result, snapshot: snapshot) : []
                    return (result, edits)
                }
                let (result, edits) = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                try Task.checkCancellation()
                // 文档身份相同仍不足以移动光标；用户切换克隆、改选区或关闭重开后原导航权已失效。
                guard generation == self.queryGeneration,
                    navigationGeneration == self.searchNavigationGeneration,
                    self.findWindow?.options == options,
                    let editor, self.mainWindow?.editor === editor, self.active?.buffer === buffer,
                    editor.document === buffer, buffer.revision == snapshot.revision,
                    editor.viewSelections == selections
                else {
                    return
                }
                guard let hit = result.hits.first else {
                    self.findWindow?.feedback.stringValue =
                        action == "replaceOne"
                        ? "当前选区不是该条件的完整匹配，请先查找。"
                        : (afterReplacement ? "已替换 1 处；" : "") + "已到达边界或没有匹配。"
                    return
                }
                guard let range = hit.range else {
                    throw NateError.message("命中切开了 UTF-16 代理项，无法无损定位；请调整表达式。")
                }
                var selected = range
                if action == "replaceOne", let edit = edits.first {
                    // 替换计划属于仍有效的原修订，提交完成后再发布新光标，避免呈现半完成状态。
                    try buffer.commit(edits, expectedRevision: snapshot.revision, name: "替换一个")
                    document.dirtyHint = document.dirtyHint || !edit.range.isEmpty || !edit.text.isEmpty
                    let end = edit.range.lower + edit.text.utf8.count
                    selected =
                        self.findWindow?.stayAfterReplace == true
                        ? ByteRange(edit.range.lower, end) : ByteRange(end, end)
                }
                buffer.selections = [TextSelection(anchor: selected.lower, head: selected.upper)]
                editor.refresh(reveal: true)
                if action != "replaceOne" || range == selected {
                    self.searchNavigationEvidence = SearchNavigationEvidence(
                        buffer: buffer,
                        editor: editor,
                        options: options,
                        selection: selected
                    )
                }
                self.findWindow?.feedback.stringValue =
                    action == "replaceOne"
                    ? "已替换 1 处。" : (afterReplacement ? "已替换 1 处；" : "") + "已定位当前匹配。"
                self.mainWindow?.refreshEditors()
                self.refreshUI()
                if action == "replaceOne", self.findWindow?.stayAfterReplace == false {
                    self.search(
                        options.backwards ? "previous" : "next",
                        options: options,
                        directory: "",
                        filters: "",
                        afterReplacement: true
                    )
                }
            }
            catch is CancellationError {
                if generation == self.queryGeneration {
                    self.findWindow?.feedback.stringValue = "已取消，未发布搜索计划。"
                }
            }
            catch {
                if generation == self.queryGeneration {
                    self.findWindow?.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }
}
