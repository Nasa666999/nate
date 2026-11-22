import AppKit
import NateSearch

extension FindReplaceWindow {
    /// 业务作用：完整用户配置只调整搜索行为与呈现，正在编辑的查询、替换、目录、历史和词来源保持原状。
    /// 参数说明:
    /// - preferences: 已完成独立偏好语义验证的完整配置。
    /// 返回：合法配置同步进入控件，不发起搜索、不递归保存或改写任何输入原文。
    public func applyUserPreferences(_ preferences: SearchUserPreferences) throws {
        try preferences.validate()
        restoringState = true
        defer {
            restoringState = false
        }
        try applyInputFont(preferences.inputFont, notify: false)
        presentationPreferences = preferences.presentation
        resultPreferences = preferences.results
        stylePreferences = preferences.styling
        mode.selectItem(at: SearchMode.allCases.firstIndex(of: preferences.options.mode) ?? 0)
        for (button, enabled) in [
            (caseSensitive, preferences.options.caseSensitive), (wholeWord, preferences.options.wholeWord),
            (dot, preferences.options.dotMatchesNewline), (backwards, preferences.options.backwards),
            (wrap, preferences.options.wrap), (selection, preferences.options.selectionOnly),
            (recursive, preferences.options.recursive), (includeHidden, preferences.options.includeHidden),
            (diskBuffers, preferences.options.ignoreOpenBuffers), (stay, preferences.stayAfterReplace),
            (confirmOpen, preferences.confirmsOpenReplacement),
            (clearPreviousMarks, preferences.marking.clearPrevious),
            (markBookmarkLines, preferences.marking.bookmarkLines),
        ] {
            button.state = enabled ? .on : .off
        }
        modeChanged()
    }
}
