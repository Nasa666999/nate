import AppKit
import NateCore
import NateSearch
import NateUI

struct MacroSearchContinuation: Equatable {
    let revision: UInt64
    let options: SearchOptions
    let selection: SelectionState?
}

private struct MacroSearchPlan: Sendable {
    let transaction: PreparedTransaction?
    let selected: ByteRange?
    let count: Int
}

extension ApplicationController {
    /// 业务作用：完成的当前文档查找与替换记录完整条件，自动跟随导航不重复录制为第二个动作。
    /// 参数说明:
    /// - action: 实际完成的搜索按钮语义。
    /// - options: 请求固定的完整搜索原文和选项。
    /// - staying: 单次替换后停留策略。
    /// - generation: 发起请求时的录制控制代次。
    /// 返回：仍属同一录制时追加完整动作；过期或不支持的范围不追加。
    func recordMacroSearch(_ action: String, options: SearchOptions, staying: Bool, generation: UUID) {
        guard macroRecording, !macroPlaying, macroRecordingGeneration == generation,
            let command = MacroSearchCommand(rawValue: action)
        else {
            return
        }
        do {
            appendRecordedMacroAction(
                .search(try MacroSearchAction(command: command, options: options, stayAfterReplace: staying))
            )
        }
        catch {
            mainWindow?.status.stringValue = "本次搜索未录入宏：" + error.localizedDescription
        }
    }

    /// 业务作用：宏搜索只读取录制时条件，在后台完整准备后复验原文档、焦点、选择和搜索输入再发布。
    /// 参数说明:
    /// - action: 录制时的完整搜索与替换策略。
    /// - continuation: 本轮同一修订和选区的空命中继续证据，其它动作会撤销它。
    /// - boundaryIsSuccess: 单次替换已完成后的自动导航无命中仍视为已完成该替换。
    /// 返回：真实搜索或替换成功为真；边界、取消、过期、表达式失败或事务拒绝为假并停止后续宏。
    func playMacroSearch(
        _ action: MacroSearchAction,
        continuation: inout MacroSearchContinuation?,
        boundaryIsSuccess: Bool = false
    ) async -> Bool {
        guard let (document, window, editor) = quickFindContext() else {
            return false
        }
        let proof = MacroPlaybackProof(document: document, window: window, editor: editor)
        let generation = macroPlayback.generation
        let input = SearchRequestInput(findWindow)
        let snapshot = document.buffer.snapshot
        let selection = editor.primarySelection?.range ?? ByteRange(0, 0)
        let continuing =
            continuation.map {
                $0.revision == snapshot.revision && $0.options == action.options
                    && $0.selection == editor.viewSelectionState && selection.isEmpty
            } ?? false
        continuation = nil
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Self.prepareMacroSearch(
                    action,
                    snapshot: snapshot,
                    selection: selection,
                    continuingEmpty: continuing
                )
            }
            let plan = try await withTaskCancellationHandler(
                operation: {
                    try await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )
            try Task.checkCancellation()
            // 原实例和所有位置证据仍一致才取得发布权，迟到结果不能沿用户的新光标或往返焦点继续。
            guard macroPlayback.generation == generation, proof.matches(self), input.matches(findWindow),
                !closing
            else {
                return false
            }
            if action.command != .replaceAll, plan.count == 0 {
                mainWindow?.status.stringValue =
                    boundaryIsSuccess ? "宏已替换 1 处；没有后续匹配。" : "宏已停止：到达搜索边界或当前选择不是完整匹配。"
                return boundaryIsSuccess
            }
            if let transaction = plan.transaction {
                // 正文与替换后的选择通过同一事务发布，后续步骤只能读取这份完整结果。
                let changed = try document.buffer.commit(transaction)
                document.dirtyHint = changed || document.dirtyHint
            }
            else if let selected = plan.selected {
                document.buffer.selections = [TextSelection(anchor: selected.lower, head: selected.upper)]
            }
            window.refreshEditors()
            refreshUI()
            mainWindow?.status.stringValue =
                action.command == .replaceAll ? "宏已替换 \(plan.count) 处。" : "宏已完成当前查找或替换。"
            if plan.selected?.isEmpty == true {
                continuation = MacroSearchContinuation(
                    revision: document.buffer.revision,
                    options: action.options,
                    selection: editor.viewSelectionState
                )
            }
            if action.command == .replaceOne, !action.stayAfterReplace {
                let next = try MacroSearchAction(
                    command: action.options.backwards ? .previous : .next,
                    options: action.options,
                    stayAfterReplace: true
                )
                return await playMacroSearch(next, continuation: &continuation, boundaryIsSuccess: true)
            }
            return true
        }
        catch {
            if proof.matchesAuthority(self), input.matches(findWindow) {
                mainWindow?.status.stringValue = "宏已停止：" + error.localizedDescription
            }
            return false
        }
    }

    /// 业务作用：搜索与替换准备沿同一快照解析真实范围，宏不使用查找窗口摘要或固定绝对坐标。
    /// 参数说明:
    /// - action: 完整当前文档动作。
    /// - snapshot: 唯一正文和选择快照。
    /// - selection: 原实际视图的主选区。
    /// - continuingEmpty: 是否排除已经选中过的起点空命中。
    /// 返回：未发布的完整命中及事务，任一表达式、预算或范围失败不产生部分结果。
    nonisolated private static func prepareMacroSearch(
        _ action: MacroSearchAction,
        snapshot: DocumentSnapshot,
        selection: ByteRange,
        continuingEmpty: Bool
    ) throws -> MacroSearchPlan {
        try action.validateSupport()
        let result: SearchResult
        if action.command == .replaceAll {
            let scope = try SearchScope.resolve(
                action: "replaceAll",
                snapshot: snapshot,
                options: action.options,
                selections: snapshot.selectionState?.selections ?? [
                    TextSelection(anchor: selection.lower, head: selection.upper)
                ]
            )
            result = try SearchEngine.find(in: snapshot, options: scope.options, scope: scope.range)
        }
        else if action.command == .replaceOne {
            result = try SearchEngine.selectedMatch(
                in: snapshot,
                options: action.options,
                selection: selection
            )
        }
        else {
            result = try SearchEngine.navigate(
                in: snapshot,
                options: action.options,
                selection: selection,
                previous: action.command == .previous,
                continuingEmpty: continuingEmpty
            )
        }
        let replacing = action.command == .replaceAll || action.command == .replaceOne
        let edits = replacing ? try SearchEngine.replacementPlan(result, snapshot: snapshot) : []
        var selected = result.hits.first?.range
        if !result.hits.isEmpty, selected == nil {
            throw NateError.message("宏命中切开了 UTF-16 代理项，未发布正文或选择。")
        }
        if action.command == .replaceOne, let edit = edits.first {
            let end = edit.range.lower + edit.text.utf8.count
            selected = action.stayAfterReplace ? ByteRange(edit.range.lower, end) : ByteRange(end, end)
        }
        let transaction =
            replacing
            ? try PreparedTransaction(
                snapshot: snapshot,
                edits: edits,
                selectionsAfter: action.command == .replaceOne
                    ? selected.map {
                        [TextSelection(anchor: $0.lower, head: $0.upper)]
                    } : nil,
                name: action.command == .replaceAll ? "宏全部替换" : "宏替换一个"
            ) : nil
        return MacroSearchPlan(transaction: transaction, selected: selected, count: result.hits.count)
    }
}
