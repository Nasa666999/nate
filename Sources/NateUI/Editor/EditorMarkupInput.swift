import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：直接结束符与语义宏使用同一标签上下文，全部闭合文字和内部光标一次发布。
    /// 参数说明: 无。
    /// 返回：完整输入成功时为真；候选、权限或词法预算不足时全部原状态保留。
    @discardableResult
    func insertMarkupTagEnd() -> Bool {
        // 标签辅助不能取得输入法候选或只读文档的写入权，重入期间也不能开始第二项输入。
        guard !confirmingComposition, composition == nil, !document.isReadOnly, !document.isEditingSuspended,
            synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许标签输入，原状态保持不变。")
            return false
        }
        guard let original = document.selectionState, case .stream = original.shape,
            language?.id == "html" || language?.id == "xml"
        else {
            return commitTextInput(
                ">",
                replacementRange: NSRange(location: NSNotFound, length: 0),
                recording: false
            )
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let permit: @Sendable () -> Bool = {
                ContinuousClock.now < deadline
            }
            let snapshot = document.snapshot
            let normalized = try original.normalized(in: snapshot.text, permit: permit)
            let targets = normalized.entries.map {
                MarkupInsertionTarget(
                    range: $0.selection.range,
                    leadingSpaces: $0.selection.virtualColumn
                )
            }
            let markup = try MarkupClosurePlan(
                snapshot: snapshot,
                dialect: language?.id == "html" ? .html : .xml,
                targets: targets,
                deadline: deadline,
                permit: permit
            )
            let insertions = try zip(normalized.entries, targets).map {
                entry,
                target in
                SelectionInsertionTarget(
                    id: entry.id,
                    range: target.range,
                    text: try markup.input(for: target, snapshot: snapshot),
                    leadingSpaces: target.leadingSpaces,
                    caretByteOffset: 1
                )
            }
            let transaction = try PreparedSelectionInsertion(
                snapshot: snapshot,
                targets: insertions,
                primaryID: normalized.primaryID,
                name: "输入标签结束符",
                permit: permit
            ).transaction
            let changed = try document.commit(transaction)
            if let state = document.selectionState {
                adoptViewSelectionState(state)
            }
            refresh(reveal: true)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            onCommand?("typingAssistance")
            if markup.nameLimitExceeded {
                onStatus?("当前标签或属性名称超过 4096 字节，已保留实际输入并暂停该目标的自动闭合。")
            }
            else if markup.conservativeScriptContext {
                onStatus?("当前 script 转义上下文保持字面输入，未猜测自动闭合标签。")
            }
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }
}
