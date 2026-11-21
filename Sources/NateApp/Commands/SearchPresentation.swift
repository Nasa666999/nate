import NateCore
import NateSearch

extension ApplicationController {
    /// 业务作用：以实际焦点视图的选区决定搜索填入和范围，克隆视图不借用另一视图的光标。
    /// 参数说明:
    /// - filling: 是否在本次打开搜索面板时读取允许的完整填入文本。
    /// 返回：可填入的完整原文；设置变化只更新选区控件，失败保留原查找内容并显示原因。
    func refreshSearchPresentation(filling: Bool = false) -> String? {
        guard let findWindow else {
            return nil
        }
        var preferences = findWindow.presentationPreferences
        if !filling {
            preferences.fillFromSelection = false
        }
        do {
            let selections: [TextSelection]
            if let editor = mainWindow?.editor, editor.document === active?.buffer {
                selections = editor.viewSelections
            }
            else {
                selections = active?.buffer.selections ?? []
            }
            let context = try SearchPresentation.context(
                text: active?.buffer.text ?? PieceTree(),
                selections: selections,
                preferences: preferences,
                wordBoundaries: mainWindow?.editor.wordBoundaries ?? currentWordBoundaries()
            )
            findWindow.applySelectionContext(context)
            return context.query
        }
        catch {
            findWindow.feedback.stringValue = error.localizedDescription
            return nil
        }
    }
}
