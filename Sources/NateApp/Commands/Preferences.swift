import AppKit
import NatePlatform

extension ApplicationController {
    /// 业务作用：通过原生界面调整自动保存、字体与主题，不要求编辑配置文件。
    /// 参数说明: 无。
    /// 返回：用户确认后发布配置，取消保持原设置。
    func showPreferences() {
        let alert = NSAlert()
        alert.messageText = "Nate 设置"
        alert.informativeText = "原文件自动保存周期固定为 1000 ms。恢复内容与原路径分别记录状态。"
        let automatic = NSButton(checkboxWithTitle: "每秒自动保存与恢复保护", target: nil, action: nil)
        automatic.state = autosaveEnabled ? .on : .off
        let fontSize = NSTextField(string: String(Int(mainWindow?.editor.font.pointSize ?? 13)))
        let defaultWrap = NSButton(checkboxWithTitle: "自动换行", target: nil, action: nil)
        defaultWrap.state = mainWindow?.editor.wrapLines == true ? .on : .off
        let symbols = NSButton(checkboxWithTitle: "显示空白符号", target: nil, action: nil)
        symbols.state = mainWindow?.editor.showSymbols == true ? .on : .off
        let view = NSStackView(views: [
            automatic, NSTextField(labelWithString: "正文等宽字号（7–72）"), fontSize, defaultWrap, symbols,
        ])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 160)
        alert.accessoryView = view
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            autosaveEnabled = automatic.state == .on
            mainWindow?.editor.font = NSFont.monospacedSystemFont(
                ofSize: max(7, min(72, fontSize.doubleValue)),
                weight: .regular
            )
            mainWindow?.editor.wrapLines = defaultWrap.state == .on
            mainWindow?.editor.showSymbols = symbols.state == .on
            UserDefaults.standard.set(autosaveEnabled, forKey: "autosaveEnabled")
            UserDefaults.standard.set(fontSize.doubleValue, forKey: "fontSize")
            UserDefaults.standard.set(defaultWrap.state == .on, forKey: "wrapLines")
            UserDefaults.standard.set(symbols.state == .on, forKey: "showSymbols")
            mainWindow?.editor.refresh()
        }
    }
}
