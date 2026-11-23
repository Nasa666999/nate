import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：视图菜单切换实际参考线并保存完整显示配置，单项意图不能覆盖未知归档或重置缩放。
    /// 参数说明:
    /// - command: 缩进参考线或长行参考线的稳定菜单身份。
    /// 返回：合法原配置保存并同步克隆；未知配置只临时切换，正文、字体、选择与撤销保持。
    func toggleReferenceGuide(_ command: String) {
        guard !closing, let window = mainWindow else {
            return
        }
        let current = currentDisplaySettings()
        let indentation =
            command == "indentGuides" ? !window.editor.showIndentGuides : window.editor.showIndentGuides
        let column: Int?
        if command == "longLineGuide" {
            column = window.editor.longLineColumn == nil ? current.longLineColumn : nil
        }
        else {
            column = window.editor.longLineColumn
        }
        do {
            let value = try EditorDisplaySettings(
                fontName: current.fontName,
                fontSize: current.fontSize,
                appearance: current.appearance,
                wrapLines: current.wrapLines,
                showSymbols: current.showSymbols,
                showIndentGuides: indentation,
                longLineColumn: column ?? current.longLineColumn,
                showLongLineGuide: column != nil,
                showModificationHistory: window.editor.showModificationHistory,
                textLinks: current.textLinks
            )
            // 单项显示意图不能据此重建无法解释的完整偏好，原归档由完整设置表单明确处理。
            if displayPreferences.sourceValid {
                try saveDisplaySettings(value, updateViews: false)
            }
            window.setReferenceGuides(indentation: indentation, column: column)
            refreshUI()
            window.status.stringValue =
                displayPreferences.sourceValid
                ? "参考线设置已保存，正文与缩放保持。"
                : "原显示配置无法读取，参考线仅本次生效；可在设置中明确应用完整配置。"
        }
        catch {
            window.status.stringValue = "参考线设置未保存：" + error.localizedDescription
        }
    }
}
