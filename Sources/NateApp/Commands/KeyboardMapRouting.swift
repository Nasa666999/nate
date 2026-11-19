import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：实际完整映射取得按键路由，旧编辑器兼容分支不再绕过用户清空或改绑。
    /// 参数说明: 无。
    /// 返回：仅监听本应用事件，不注册系统全局快捷键；输入法与明确捕获控件保留优先权。
    func connectKeyboardMap() {
        let runtime = keyboardMap
        guard runtime.ready, runtime.resolution != nil, mainWindow != nil else {
            return
        }
        mainWindow?.setDefaultKeyboardRoutes(active: false)
        var descriptions: [String: String] = [:]
        for entry in runtime.catalog {
            let keys = (runtime.resolution?.active[entry.id] ?? []).map {
                NativeKeyboardShortcut.label($0)
            }.joined(separator: "、")
            descriptions[entry.id] = entry.title + (keys.isEmpty ? "" : " · " + keys)
        }
        mainWindow?.setCommandTooltips(descriptions)
        guard runtime.monitor == nil else {
            return
        }
        runtime.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else {
                return event
            }
            return self.routeKeyboardEvent(event) ? nil : event
        }
    }

    /// 业务作用：命令按键只沿当前真实所有者执行，候选、捕获、失效目录和窗口外事件不取得命令执行权。
    /// 参数说明:
    /// - event: 由本应用事件循环收到的按键。
    /// 返回：已拥有并处理组合时为真，其它事件继续进入原生输入系统。
    func routeKeyboardEvent(_ event: NSEvent) -> Bool {
        let runtime = keyboardMap
        guard !closing, runtime.ready, let resolution = runtime.resolution,
            let window = NSApp.keyWindow, event.windowNumber == window.windowNumber
        else {
            return false
        }
        let responder = window.firstResponder
        if let capture = responder as? MacroShortcutCapture, capture.isCapturing {
            return false
        }
        if let editor = responder as? EditorView, editor.handlePriorityKeyboardEvent(event) {
            return true
        }
        // 已标记候选先拥有全部确认和取消按键，配置不能在候选进入正文前改变文档、焦点或菜单状态。
        if let client = responder as? any NSTextInputClient, client.hasMarkedText() {
            responder?.keyDown(with: event)
            return true
        }
        guard let shortcut = try? NativeKeyboardShortcut.capture(event),
            let owner = resolution.owners[shortcut],
            let entry = runtime.catalog.first(where: {
                $0.id == owner
            })
        else {
            return false
        }
        if entry.managedElsewhere {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.representedObject = entry.id
            if validateMenuItem(item) {
                route(entry.id)
            }
            return true
        }
        guard let item = entry.items.first, let action = item.action else {
            return false
        }
        if item.target === self {
            if validateMenuItem(item) {
                _ = NSApp.sendAction(action, to: self, from: item)
            }
            return true
        }
        // 原生复制、剪切和全选始终沿当前响应链，管理搜索框不会误操作后台正文。
        guard let target = NSApp.target(forAction: action, to: item.target, from: item) else {
            return true
        }
        if let validation = target as? any NSUserInterfaceValidations,
            !validation.validateUserInterfaceItem(item)
        {
            return true
        }
        if let validation = target as? any NSMenuItemValidation, !validation.validateMenuItem(item) {
            return true
        }
        _ = NSApp.sendAction(action, to: target, from: item)
        return true
    }
}
