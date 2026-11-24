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
            range.lower >= 0, range.upper >= range.lower,
            range.count <= CompletionInputCommand.maximumPrefixBytes,
            primarySelection?.head == range.upper, document.text.isBoundary(range.lower),
            document.text.isBoundary(range.upper), result.candidates.count <= 200,
            !result.context.prefixExceedsLimit || result.candidates.isEmpty,
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
                stillCurrent?() != false,
                result.candidates.contains(where: { $0.text.utf8.elementsEqual(text.utf8) })
            else {
                return
            }
            self.completionPresentation = UUID()
            do {
                let command = try CompletionInputCommand(prefix: result.context.prefix, replacement: text)
                self.submitCompletion(command)
            }
            catch {
                self.onStatus?(error.localizedDescription)
            }
        }
        let limitMessage: String? =
            if result.context.prefixExceedsLimit {
                "当前前缀超过补全预算，可缩短后再试。"
            }
            else if result.limited {
                "候选受当前扫描或结果上限限制。"
            }
            else {
                nil
            }
        panel.present(in: self, values: result.candidates, hint: signature, limitMessage: limitMessage)
    }

    /// 业务作用：原生候选与语义宏使用同一个完整前缀替换事务，实际发布后才通知录制。
    /// 参数说明:
    /// - command: 已确认的当前单行原前缀及完整候选文字。
    /// 返回：替换成功或候选本来等于前缀时为真；来源与权限不足时为假，停止宏的后续动作。
    @discardableResult
    public func submitCompletion(_ command: CompletionInputCommand) -> Bool {
        // 播放没有旧候选窗口的授权，必须重新取得目前真实编辑视图的写入资格。
        guard completionSource() != nil else {
            onStatus?("当前正文焦点或编辑权限不允许确认补全。")
            return false
        }
        do {
            let changed = try document.commit(command.prepare(in: document.snapshot))
            refresh(reveal: true)
            if changed {
                onCompletionInput?(command)
                onChange?()
            }
            else {
                onSelection?()
            }
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：切换或编辑后撤去旧候选，避免过期前缀继续呈现。
    /// 参数说明: 无。
    /// 返回：补全面板隐藏，正文与光标保持原状。
    public func dismissCompletion() {
        completionPresentation = UUID()
        completionPanel?.hide()
    }
}
