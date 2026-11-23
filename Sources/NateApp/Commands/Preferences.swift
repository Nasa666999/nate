import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：原生设置编辑完整显示与自动保存草稿，只有原偏好来源仍有效时才允许应用。
    /// 参数说明: 无。
    /// 返回：明确应用后同步现有克隆并保存配置；取消、非法草稿或来源变化保留原设置。
    func showPreferences() {
        // 模态窗口不能借焦点转移消费尚未提交的候选，原输入状态先保留在正文视图。
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let saved = currentDisplaySettings()
        let runtime = displayPreferences
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = displayPreferenceSource(domain)
        let editor = mainWindow?.editor
        let initial =
            (try? EditorDisplaySettings(
                fontName: saved.fontName,
                fontSize: Double(editor?.font.pointSize ?? CGFloat(saved.fontSize)),
                appearance: saved.appearance,
                wrapLines: editor?.wrapLines ?? saved.wrapLines,
                showSymbols: editor?.showSymbols ?? saved.showSymbols,
                showIndentGuides: editor?.showIndentGuides ?? saved.showIndentGuides,
                longLineColumn: editor?.longLineColumn ?? saved.longLineColumn,
                showLongLineGuide: editor == nil ? saved.showLongLineGuide : editor?.longLineColumn != nil,
                showModificationHistory: editor?.showModificationHistory ?? saved.showModificationHistory
            )) ?? saved
        let form = EditorDisplayForm(settings: initial)
        let automatic = NSButton(checkboxWithTitle: "每秒自动保存与恢复保护", target: nil, action: nil)
        automatic.state = autosaveEnabled ? .on : .off
        let status = NSTextField(wrappingLabelWithString: runtime.warning ?? "")
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 420
        let content = NSStackView(views: [automatic, form, status])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let alert = NSAlert()
        alert.messageText = "Nate 设置"
        alert.informativeText = "原文件自动保存周期固定为 1000 ms。字体、显示和主题变化不修改正文。"
        alert.accessoryView = content
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while !closing {
            content.setFrameSize(NSSize(width: 420, height: max(320, content.fittingSize.height)))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            alert.window.makeFirstResponder(nil)
            // 表单只持有打开时的偏好来源，外部更改或其它明确应用后必须重新打开草稿。
            guard !closing, runtime.generation == generation,
                (runtime.defaults ?? .standard) === domain,
                source.isEqual(displayPreferenceSource(domain))
            else {
                runtime.loaded = false
                mainWindow?.status.stringValue = "设置来源已改变，旧表单未保存，请重新打开。"
                return
            }
            do {
                let selected = try form.settings()
                try saveDisplaySettings(selected)
                autosaveEnabled = automatic.state == .on
                domain.set(autosaveEnabled, forKey: "autosaveEnabled")
                refreshUI()
                mainWindow?.status.stringValue = runtime.warning ?? "显示与自动保存设置已应用。"
                return
            }
            catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
