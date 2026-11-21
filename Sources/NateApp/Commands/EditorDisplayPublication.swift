import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：明确应用后保存完整显示配置，编码与容量确认完成后才发布外观与克隆排版。
    /// 参数说明:
    /// - settings: 完整合法的显示配置。
    /// - updateViews: 是否同时应用字体和显示选项；主题菜单只改变外观并保留当前缩放。
    /// 返回：成功时持久化整份配置，失败时保留原配置和呈现。
    func saveDisplaySettings(_ settings: EditorDisplaySettings, updateViews: Bool = true) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，显示设置未保存。")
        }
        let data = try JSONEncoder().encode(settings)
        guard data.count <= 4096 else {
            throw NateError.message("完整显示配置超过 4 KiB。")
        }
        let runtime = displayPreferences
        let domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "editorDisplaySettings")
        runtime.loaded = false
        runtime.warning = nil
        runtime.sourceValid = true
        runtime.generation = UUID()
        // 字体与外观没有正文写入权限，重建排版后仍使用各视图自己的修订和选择证据。
        applyDisplaySettings(settings, to: updateViews ? mainWindow : nil)
    }

    /// 业务作用：主题菜单保存明确选择并同步语言外观，不把当前临时缩放重置为持久化字号。
    /// 参数说明:
    /// - appearance: 用户明确选择的系统、浅色或深色外观。
    /// 返回：合法来源保存后应用外观；未知完整配置只临时切换并保留原归档，保存失败在原窗口反馈。
    func chooseEditorAppearance(_ appearance: EditorAppearance) {
        let current = currentDisplaySettings()
        do {
            let settings = try EditorDisplaySettings(
                fontName: current.fontName,
                fontSize: current.fontSize,
                appearance: appearance,
                wrapLines: current.wrapLines,
                showSymbols: current.showSymbols
            )
            // 主题菜单只有单项外观意图，不能据此覆盖无法解释的完整字体和显示配置。
            guard displayPreferences.sourceValid else {
                applyDisplaySettings(settings, to: nil)
                refreshUI()
                mainWindow?.status.stringValue = "原显示配置无法读取，主题仅本次生效；可在设置中明确应用完整新配置。"
                return
            }
            try saveDisplaySettings(settings, updateViews: false)
            refreshUI()
        }
        catch {
            mainWindow?.status.stringValue = "主题选择未保存：" + error.localizedDescription
        }
    }
}
