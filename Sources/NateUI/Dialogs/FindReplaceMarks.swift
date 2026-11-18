import AppKit

extension FindReplaceWindow {
    /// 业务作用：标记动作使用独立颜色保留策略，书签附加行为必须来自明确勾选。
    /// 参数说明: 无。
    /// 返回：当前已确认的标记偏好，不改变搜索表达式或正文。
    public var markPreferences: SearchMarkPreferences {
        var result = SearchMarkPreferences()
        result.clearPrevious = clearPreviousMarks.state == .on
        result.bookmarkLines = markBookmarkLines.state == .on
        return result
    }

    /// 业务作用：标记页明确区分颜色、书签和复制，清除颜色不会借选项隐式清空原书签。
    /// 参数说明:
    /// - root: 查找窗口共享的垂直内容区域。
    /// 返回：标记页具有独立偏好与实际动作，其他页隐藏该选项区域。
    func installMarkControls(in root: NSStackView) {
        for option in [clearPreviousMarks, markBookmarkLines] {
            option.target = self
            option.action = #selector(optionsChanged)
            markOptions.addArrangedSubview(option)
        }
        clearPreviousMarks.toolTip = "仅在本次标记完整成功后清除旧查找颜色，五组样式和既有书签保持独立。"
        markBookmarkLines.toolTip = "给本次匹配涉及的全部逻辑行添加书签，不清除原书签。"
        markOptions.spacing = 8
        root.addArrangedSubview(markOptions)
        for (id, title) in [
            ("highlight", "标记全部"), ("mark", "添加匹配行书签"),
            ("clearSearchMarks", "清除查找标记"), ("copySearchMarks", "复制标记文本"),
        ] {
            markActions.addArrangedSubview(button(id, title))
        }
    }
}
