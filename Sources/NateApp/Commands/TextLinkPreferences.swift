import NateCore

extension ApplicationController {
    /// 业务作用：仅编辑链接或自动保存时保留持久化字体及每个克隆的临时缩放，整份归档仍统一保存。
    /// 参数说明:
    /// - selected: 用户明确应用的完整表单。
    /// - initial: 表单打开时的实际呈现，用于识别字体和显示意图。
    /// - saved: 表单打开时的持久化配置。
    /// 返回：纯链接应用不重建正文布局；其它显示变化沿正常完整发布路径处理，失败不发布部分草稿。
    func applyDisplayDraft(
        _ selected: EditorDisplaySettings,
        initial: EditorDisplaySettings,
        saved: EditorDisplaySettings
    ) throws {
        guard selected.fontName == initial.fontName, selected.fontSize == initial.fontSize,
            selected.appearance == initial.appearance, selected.wrapLines == initial.wrapLines,
            selected.showSymbols == initial.showSymbols,
            selected.showIndentGuides == initial.showIndentGuides,
            selected.longLineColumn == initial.longLineColumn,
            selected.showLongLineGuide == initial.showLongLineGuide,
            selected.showModificationHistory == initial.showModificationHistory
        else {
            try saveDisplaySettings(selected)
            return
        }
        let settings = try EditorDisplaySettings(
            fontName: saved.fontName,
            fontSize: saved.fontSize,
            appearance: selected.appearance,
            wrapLines: selected.wrapLines,
            showSymbols: selected.showSymbols,
            showIndentGuides: selected.showIndentGuides,
            longLineColumn: selected.longLineColumn,
            showLongLineGuide: selected.showLongLineGuide,
            showModificationHistory: selected.showModificationHistory,
            textLinks: selected.textLinks
        )
        try saveDisplaySettings(settings, updateViews: false)
        mainWindow?.setTextLinks(settings.textLinks)
    }
}
