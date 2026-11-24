import AppKit

extension ApplicationController: NSMenuDelegate {
    /// 业务作用：文档搜索只允许切换发起窗口的原有标签，由统一激活入口处理原输入。
    /// 参数说明: 无。
    /// 返回：搜索无结果、取消或来源失效时不切换正文；有效结果经窗口和标签复验后激活。
    func searchOpenDocuments() {
        guard !closing, let owner = mainWindow, isWorkspaceWindowAvailable(owner) else {
            return
        }
        let generation = owner.tabOrderIdentity
        owner.searchDocumentList { [weak self, weak owner] id in
            // 先校验原窗口、原代次和目标存续，再交给会确认原编辑候选的切换入口。
            guard let self, let owner, !closing, mainWindow === owner, isWorkspaceWindowAvailable(owner),
                owner.tabOrderIdentity == generation, workspaceTabIDs(in: owner).contains(id),
                documents.contains(where: { $0.buffer.id == id && !$0.closing })
            else {
                owner?.status.stringValue = "文档列表已改变，请重新打开后选择。"
                return
            }
            activate(id, in: owner)
        }
    }

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
