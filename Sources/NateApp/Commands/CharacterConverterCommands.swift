import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：打开双向字符进制面板，并只从实际正文焦点固定可插入目标。
    /// 参数说明: 无。
    /// 返回：所有字段可独立互转与复制；没有明确正文来源时仍可计算，但不能插入。
    func characterConverter() {
        // 未确认候选属于输入法，转换窗口不能借切换焦点消费或丢弃候选。
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let source = quickFindContext()
        textTools.converterPanel?.close()
        let panel = CharacterConverterPanel()
        if let (document, window, editor) = source {
            textTools.converterOrigin = RunCommandSourceProof(
                document: document,
                window: window,
                editor: editor
            )
            panel.insertionEnabled = !document.buffer.isReadOnly && !document.buffer.isEditingSuspended
        }
        panel.onInsert = {
            [weak self, weak panel] value in
            guard let self, let panel else {
                return false
            }
            return self.insertConvertedField(value, panel: panel)
        }
        panel.onClose = {
            [weak self, weak panel] in
            if self?.textTools.converterPanel === panel {
                self?.textTools.converterPanel = nil
                self?.textTools.converterOrigin = nil
            }
        }
        textTools.converterPanel = panel
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：字段插入复验打开面板时的正文、选择与权限，成功才沿标准文本输入维护撤销和宏。
    /// 参数说明:
    /// - value: 当前有效字段生成的完整文本，不解释为原始八位字节。
    /// - panel: 用户明确点击插入的当前面板。
    /// 返回：原来源有效且实际输入成功时为真；失效不改写后来正文或新选区。
    func insertConvertedField(_ value: String, panel: CharacterConverterPanel) -> Bool {
        // 面板焦点变化不授予新正文写入权，选择或权限往返也必须重新打开取得来源。
        guard !closing, textTools.converterPanel === panel,
            let proof = textTools.converterOrigin, proof.matches(self),
            !proof.document.buffer.isReadOnly, !proof.document.buffer.isEditingSuspended,
            !proof.window.hasMarkedEditorInput
        else {
            panel.insertionEnabled = false
            panel.status.stringValue = "原正文、选区或编辑权限已改变，请从实际正文重新打开面板。"
            return false
        }
        // 明确插入先恢复同一正文的实际输入焦点，标准输入与宏录制才能共享完整来源门禁。
        proof.window.window?.makeKeyAndOrderFront(nil)
        guard proof.window.window?.makeFirstResponder(proof.editor) == true,
            quickFindContext()?.2 === proof.editor, proof.matches(self), proof.editor.submitText(value)
        else {
            panel.status.stringValue = "字段未插入，原正文和选择保持不变。"
            return false
        }
        // 只接续本次真实输入发布后的选择，外部选择变化仍会撤去下次插入资格。
        textTools.converterOrigin = RunCommandSourceProof(
            document: proof.document,
            window: proof.window,
            editor: proof.editor
        )
        return true
    }
}
