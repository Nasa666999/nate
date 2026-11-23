import AppKit
import Foundation

extension EditorWindow {
    /// 业务作用：显示开关同步现有克隆但不清除修改记录，重新开启后继续呈现当前完整保存分类。
    /// 参数说明:
    /// - enabled: 是否显示修改历史边栏及正文指示。
    /// 返回：全部克隆只更新绘制开关，正文、保存点、缩放与选择保持。
    public func setModificationHistory(_ enabled: Bool) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                continue
            }
            editor.showModificationHistory = enabled
            editor.modificationDisplayStatus = nil
            editor.needsDisplay = true
        }
    }

    /// 业务作用：保存分类变化只重绘对应正文及克隆，不改变布局、缩放、输入法或矩形选择证据。
    /// 参数说明:
    /// - documentID: 已完成保存类别核对的共享文档身份。
    /// 返回：属于该文档的现有视图被安排重绘，其它文档和所有正文状态保持。
    public func redrawModifications(documentID: UUID) {
        for view in editorSplit.arrangedSubviews {
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView,
                editor.document.id == documentID
            else {
                continue
            }
            editor.needsDisplay = true
        }
    }
}
