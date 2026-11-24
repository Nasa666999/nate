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
    /// - stillCurrent: 调用方独立的请求和路径绑定是否仍具备实际提交资格。
    /// 返回：面板显示；失效候选不会修改正文。
    public func presentCompletions(
        _ result: CompletionResult,
        signature: SignatureHint?,
        tab: Bool,
        enter: Bool,
        stillCurrent: (@MainActor () -> Bool)? = nil
    ) {
        let range = result.context.range
        // 同一文档标识和修订不能替代原始前缀证据，任一不符都不能显示可写入的候选。
        guard let source = completionSource(), stillCurrent?() != false,
            result.documentID == document.id, result.revision == document.revision,
            range.lower >= 0, range.upper >= range.lower, range.count <= 65_536,
            primarySelection?.head == range.upper, document.text.isBoundary(range.lower),
            document.text.isBoundary(range.upper), result.candidates.count <= 200,
            document.text.bytes(in: range).elementsEqual(result.context.prefix.utf8)
        else {
            return
        }
        let presentation = UUID()
        completionPresentation = presentation
        let panel = completionPanel ?? CompletionPanel()
        completionPanel = panel
        panel.confirmsTab = tab
        panel.confirmsEnter = enter
        panel.onChoose = {
            [weak self] text in
            // 请求替换、焦点交接、重新选择或权限变化都能使仍在屏幕上的旧候选失去正文写入资格。
            guard let self, self.completionPresentation == presentation, source.isCurrent(),
                stillCurrent?() != false, let entry = self.viewSelectionState?.primary,
                result.candidates.contains(where: { $0.text.utf8.elementsEqual(text.utf8) })
            else {
                return
            }
            self.completionPresentation = UUID()
            do {
                let prepared = try PreparedSelectionInsertion(
                    snapshot: self.document.snapshot,
                    targets: [SelectionInsertionTarget(id: entry.id, range: range, text: text)],
                    name: "补全"
                )
                let changed = try self.document.commit(prepared.transaction)
                self.refresh(reveal: true)
                if changed {
                    self.onChange?()
                }
                else {
                    self.onSelection?()
                }
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
        completionPresentation = UUID()
        completionPanel?.hide()
    }
}
