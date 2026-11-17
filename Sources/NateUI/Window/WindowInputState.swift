import AppKit

extension EditorWindow {
    /// 业务作用：识别所有正文视图尚未确认的候选，搜索命令不能通过切换焦点或修改共享缓冲区提前提交、丢弃候选。
    /// 参数说明: 无。
    /// 返回：主视图或任一克隆持有原生组合输入时为真。
    public var hasMarkedEditorInput: Bool {
        editorSplit.arrangedSubviews.contains {
            (($0 as? NSScrollView)?.documentView as? EditorView)?.hasMarkedText() == true
        }
    }
}
