import AppKit

extension SearchResultsPanel {
    /// 业务作用：来源相关操作集中在原生菜单中，窄窗口仍保留结果导航和筛选空间。
    /// 参数说明: 无。
    /// 返回：只在用户点击命令时请求读取完整源行的菜单。
    func sourceActions() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.addItem(withTitle: "更多")
        let copy = NSMenuItem(title: "复制命中行", action: #selector(copySourceLines), keyEquivalent: "")
        copy.target = self
        copy.toolTip = "复验来源后复制所选命中覆盖的完整源行，去除路径和行号；源行之间使用 LF。"
        popup.menu?.addItem(copy)
        return popup
    }
}
