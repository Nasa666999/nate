import AppKit

extension ApplicationController: NSMenuDelegate {
    /// 业务作用：窗口菜单实际展开时读取最新文档顺序，后台保存不重建正在跟踪的菜单。
    /// 参数说明:
    /// - menu: 即将显示的原生菜单。
    /// 返回：只更新本应用的窗口文档项，保留其它系统管理项与静态命令。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === NSApp.windowsMenu else {
            return
        }
        populateWindowDocuments(in: menu)
    }

    /// 业务作用：窗口菜单与工具栏使用同一份原生列表，名称、状态、顺序和身份始终一致。
    /// 参数说明:
    /// - menu: 当前窗口菜单。
    /// 返回：替换原文档项，静态命令和系统窗口项继续保留，不打开任何正文。
    func populateWindowDocuments(in menu: NSMenu) {
        let previous = menu.items.filter {
            ($0.representedObject as? String)?.hasPrefix("activate:") == true
                || $0.identifier?.rawValue == "nate.documentListOrder"
        }
        for item in previous {
            menu.removeItem(item)
        }
        guard let window = mainWindow else {
            return
        }
        let list = window.documentListMenu(target: self, action: #selector(menuAction(_:)))
        menu.addItem(window.documentListOrderItem(target: self, action: #selector(menuAction(_:))))
        for item in list.items {
            list.removeItem(item)
            menu.addItem(item)
        }
    }
}
