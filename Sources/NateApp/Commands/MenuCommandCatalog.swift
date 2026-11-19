import AppKit

extension ApplicationController {
    /// 业务作用：命令提示读取实际完整菜单中的名称，快捷键、宏录制和菜单分发使用相同稳定身份。
    /// 参数说明:
    /// - id: 统一路由中的命令身份。
    /// - root: 正在构建的菜单根，省略时读取当前应用菜单。
    /// 返回：当前菜单提供该命令时的用户名称，不存在时为空；不触发命令或检查正文。
    func menuCommandTitle(_ id: String, in root: NSMenu? = nil) -> String? {
        var pending = (root ?? NSApp.mainMenu)?.items ?? []
        while let item = pending.popLast() {
            if item.representedObject as? String == id {
                return item.title
            }
            pending.append(contentsOf: item.submenu?.items ?? [])
        }
        return nil
    }
}
