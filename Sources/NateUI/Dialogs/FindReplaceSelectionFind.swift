import AppKit

extension FindReplaceWindow {
    /// 业务作用：Select and Find 明确采用所选原文作为当前查询并记录最近使用，普通填入偏好不阻止显式动作。
    /// 参数说明:
    /// - text: 已按填入字符与 UTF-8 容量验证的完整字面查询。
    /// 返回：无候选或全文草稿且查询合法时更新原文与查询历史；不改替换内容、匹配模式、页面或焦点。
    @discardableResult
    public func useSelectionForFind(_ text: String) -> Bool {
        guard !isEditingInput, !text.isEmpty, text.utf8.count <= 1_048_576 else {
            return false
        }
        // 显式快捷动作已撤销旧请求，原文替换不再通过普通输入回调取消拥有此次更新权的任务。
        let previous = onInputBegan
        onInputBegan = nil
        defer {
            onInputBegan = previous
        }
        query.stringValue = text
        remember(query, history: &queryHistory)
        stateChanged()
        return true
    }
}
