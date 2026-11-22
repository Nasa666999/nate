import AppKit

extension ApplicationController {
    /// 业务作用：当前双视图的同步方向独立切换，菜单动作本身不移动光标或确认候选。
    /// 参数说明:
    /// - vertical: 当前明确切换垂直方向，为假时切换水平方向。
    /// 返回：真实双视图采用新开关，旧菜单在分屏已关闭时不改变任何状态。
    func toggleScrollSynchronization(vertical: Bool) {
        // 菜单展开以后可能已移除克隆，旧入口不能重新为失效容器登记同步资格。
        guard !closing, let window = mainWindow, window.hasDualEditorViews else {
            return
        }
        if vertical {
            window.setScrollSynchronization(vertical: !window.verticalScrollSynchronized)
        }
        else {
            window.setScrollSynchronization(horizontal: !window.horizontalScrollSynchronized)
        }
    }

    /// 业务作用：同步菜单直接反映当前窗口的两个独立开关，仅真实双视图可以执行。
    /// 参数说明:
    /// - item: 当前原生菜单项，用于显示实际开关。
    /// - id: 原生菜单的稳定同步命令身份。
    /// 返回：同步入口的实际可用性，其它命令交还既有规则。
    func validateScrollSynchronizationMenu(_ item: NSMenuItem, id: String) -> Bool? {
        guard id == "syncVerticalScroll" || id == "syncHorizontalScroll" else {
            return nil
        }
        let enabled =
            id == "syncVerticalScroll"
            ? mainWindow?.verticalScrollSynchronized : mainWindow?.horizontalScrollSynchronized
        item.state = enabled == true ? .on : .off
        return !closing && mainWindow?.hasDualEditorViews == true
    }
}
