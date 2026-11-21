import AppKit
import NateCore

extension EditorView {
    /// 业务作用：直接配对输入与语义宏沿同一完整事务提交，插入内部光标不制造第二次正文操作。
    /// 参数说明:
    /// - command: 已明确固定的配对定义、实际字符和闭合越过选项。
    /// 返回：完整提交时为真并通知独立宏事件；候选、权限、矩形或准备失败时全部原状态保持不变。
    @discardableResult
    public func submitPairInput(_ command: PairInputCommand) -> Bool {
        // 配对不能借输入辅助提前消费候选或取得只读文档的选择修改权。
        guard !confirmingComposition, composition == nil, !document.isReadOnly, !document.isEditingSuspended,
            synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许配对输入，原状态保持不变。")
            return false
        }
        do {
            let prepared = try PreparedPairInsertion(snapshot: document.snapshot, command: command)
            let changed = try document.commit(prepared.transaction)
            if let state = document.selectionState {
                adoptViewSelectionState(state)
            }
            refresh(reveal: true)
            onPairInput?(command)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            onCommand?("typingAssistance")
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }
}
