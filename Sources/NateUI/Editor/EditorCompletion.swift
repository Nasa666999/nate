import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：补全确认仍通过唯一编辑事务，并在确认时重新验证原光标与修订。
    /// 参数说明:
    /// - result: 当前请求的有界候选和前缀证据。
    /// - signature: 当前函数调用说明。
    /// - tab: Tab 是否确认候选。
    /// - enter: Enter 是否确认候选。
    /// 返回：面板显示；失效候选不会修改正文。
    public func presentCompletions(
        _ result: CompletionResult,
        signature: SignatureHint?,
        tab: Bool,
        enter: Bool
    ) {
        guard result.documentID == document.id, result.revision == document.revision,
            !hasComposition, window?.firstResponder === self
        else {
            return
        }
        let panel = completionPanel ?? CompletionPanel()
        completionPanel = panel
        panel.confirmsTab = tab
        panel.confirmsEnter = enter
        panel.onChoose = {
            [weak self] text in
            guard let self, self.document.id == result.documentID,
                self.document.revision == result.revision, self.viewSelections.count == 1,
                self.primarySelection?.head == result.context.range.upper,
                self.primarySelection?.range.isEmpty == true, !self.hasComposition
            else {
                return
            }
            do {
                let head = result.context.range.lower + text.utf8.count
                try self.document.commit(
                    [TextEdit(result.context.range, text)],
                    expectedRevision: result.revision,
                    selectionsAfter: [TextSelection(anchor: head, head: head)],
                    name: "补全"
                )
                self.refresh(reveal: true)
                self.onChange?()
            }
            catch {
                self.onStatus?(error.localizedDescription)
            }
        }
        panel.present(in: self, values: result.candidates, hint: signature, limited: result.limited)
    }

    /// 业务作用：切换或编辑后撤去旧候选，避免过期前缀继续呈现。
    /// 参数说明: 无。
    /// 返回：补全面板隐藏，正文与光标保持原状。
    public func dismissCompletion() {
        completionPanel?.hide()
    }
}
