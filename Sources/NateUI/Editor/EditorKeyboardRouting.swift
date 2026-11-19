import AppKit

extension EditorView {
    /// 业务作用：输入法与补全候选先取得本次按键，命令映射不能截走确认、取消或候选导航。
    /// 参数说明:
    /// - event: 应用本地事件循环中的真实按键。
    /// 返回：已交给输入法或补全候选时为真，普通事件继续检查当前命令映射。
    public func handlePriorityKeyboardEvent(_ event: NSEvent) -> Bool {
        if hasMarkedText() {
            interpretKeyEvents([event])
            return true
        }
        return completionPanel?.handle(event) == true
    }
}
