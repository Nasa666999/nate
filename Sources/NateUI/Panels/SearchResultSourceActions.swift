import AppKit

extension SearchResultsPanel {
    /// 业务作用：来源相关操作集中在原生菜单中，窄窗口仍保留结果导航和筛选空间。
    /// 参数说明: 无。
    /// 返回：只在用户点击命令时读取完整源行或打开所选路径的菜单。
    func sourceActions() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.addItem(withTitle: "更多")
        let copy = NSMenuItem(title: "复制命中行", action: #selector(copySourceLines), keyEquivalent: "")
        copy.target = self
        copy.toolTip = "复验来源后复制所选命中覆盖的完整源行，去除路径和行号；源行之间使用 LF。"
        popup.menu?.addItem(copy)
        let open = NSMenuItem(title: "打开所选路径", action: #selector(openSelectedResultPaths), keyEquivalent: "")
        open.target = self
        open.toolTip = "打开当前选择的可见路径，读取当前文件，不使用旧匹配偏移；一次最多二十个路径。"
        popup.menu?.addItem(open)
        return popup
    }
}
