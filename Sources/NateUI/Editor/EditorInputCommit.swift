import AppKit
import NateCore

extension EditorView {
    /// 业务作用：组合只能写入原正文、原完整选择和原编辑权限，权限往返不能恢复旧候选的提交资格。
    /// 参数说明:
    /// - session: 系统已经建立的原组合证据。
    /// 返回：所有来源与控制代次仍一致时为真，不改变组合或正文。
    func compositionIsCurrent(_ session: CompositionSession) -> Bool {
        session.revision == document.revision
            && session.selectionGeneration == selectionGeneration
            && session.selectionState == viewSelectionState
            && session.documentSelectionGeneration == document.selectionGeneration
            && session.editingGeneration == document.editingAuthorityGeneration
    }

    /// 业务作用：确认输入的完整事务成功后才撤去组合，容量或边界失败保留仍有效候选供重试或取消。
    /// 参数说明:
    /// - value: 系统最终确认或用户直接输入的完整文字。
    /// - replacementRange: 没有原组合时可指定的 UTF-16 主项替换范围。
    /// 返回：真实提交或相同字节选择收束成功时为真；失败不推进后续导航、保存或关闭。
    @discardableResult
    func commitTextInput(_ value: String, replacementRange: NSRange) -> Bool {
        guard !confirmingComposition else {
            return false
        }
        let session = composition
        if let session, !compositionIsCurrent(session) {
            // 来源失效无法安全重试，先撤去旧组合；这次请求仍失败，不能顺势执行后续动作。
            composition = nil
            inputContext?.discardMarkedText()
            refresh()
            onStatus?("原输入法组合的正文、选择或权限已改变，本次确认未提交。")
            return false
        }
        guard !document.isReadOnly, !document.isEditingSuspended else {
            onStatus?("文档当前不能提交输入，候选与正文保持原状。")
            return false
        }
        var replacement = session?.replacementOverride
        if session == nil, replacementRange.location != NSNotFound {
            guard let range = document.text.byteRange(replacementRange) else {
                onStatus?("系统替换范围不是当前正文的完整 UTF-16 边界。")
                return false
            }
            replacement = range
        }
        guard synchronizeDocumentSelectionState() else {
            return false
        }
        // 组合仍归输入法持有；准备矩形边缘时临时使用已提交正文布局，重入回调不能重复确认。
        confirmingComposition = true
        layouts.removeAll()
        defer {
            confirmingComposition = false
        }
        do {
            try requireCurrentRectangleLayout()
            let changed: Bool
            if replacement == nil, let state = viewSelectionState, case .rectangle = state.shape {
                changed = try document.commit(
                    prepareRectangularInput(value, overwrite: session == nil && overwrite)
                )
            }
            else {
                changed = try document.insert(
                    value,
                    replacementRange: replacement,
                    overwrite: session == nil && overwrite
                )
            }
            // 正文和完整结果选择已经串行发布，随后解除组合只影响展示，不再拥有第二次正文写入权。
            composition = nil
            confirmingComposition = false
            refresh(reveal: true)
            onTextInput?(value)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            if session != nil {
                onCommand?("compositionEnded")
            }
            if !value.isEmpty && value.utf16.count <= 2 {
                onCommand?("typingAssistance")
            }
            return true
        }
        catch {
            if var retained = session, compositionIsCurrent(retained), value.utf8.count <= 1_048_576 {
                retained.text = value
                let start = min(retained.selected.location, value.utf16.count)
                retained.selected = NSRange(
                    location: start,
                    length: min(retained.selected.length, value.utf16.count - start)
                )
                composition = retained
            }
            confirmingComposition = false
            refresh()
            onStatus?(error.localizedDescription)
            NSSound.beep()
            return false
        }
    }
}
