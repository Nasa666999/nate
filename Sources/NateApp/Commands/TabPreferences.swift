import AppKit
import NateCore
import NateUI

private struct TabPreferencesArchive: Codable {
    let format: Int
    let settings: LanguageTabSettings
}

@MainActor
final class TabPreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = LanguageTabSettings()
    var warning: String?
    var layoutWarning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var sourceObject: NSObject?

    /// 业务作用：语言 Tab 配置独立于正文和恢复归档，读取异常不阻止原文件编辑或保存。
    /// 参数说明: 无。
    /// 返回：尚未读取偏好、采用四列空格 Tab 的独立运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：完整读取默认与语言覆盖项，未知或损坏归档保留原值并明确使用默认规则。
    /// 参数说明: 无。
    /// 返回：当前完整配置；未能解释的偏好不被自动覆盖。
    func currentTabSettings() -> LanguageTabSettings {
        let runtime = tabPreferences
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "languageTabSettings") as? NSObject
        if runtime.loaded, runtime.sourceDomain === domain,
            runtime.sourceObject.map({
                $0.isEqual(object)
            }) ?? (object == nil)
        {
            return runtime.settings
        }
        runtime.settings = LanguageTabSettings()
        runtime.loaded = true
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.sourceObject = object
        runtime.generation = UUID()
        if let object {
            do {
                guard let data = object as? Data, data.count <= 512 * 1024 else {
                    throw NateError.message("语言 Tab 设置不是 512 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(TabPreferencesArchive.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("语言 Tab 设置格式尚不受支持。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "Tab 设置未被读取，原归档保留；本次采用四列空格 Tab。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：明确应用整份规则后才保存偏好，不因查看配置或切换语言重写归档。
    /// 参数说明:
    /// - settings: 已验证完整默认与语言覆盖项的配置。
    /// 返回：完整编码成功后一次保存并更新当前视图；超量或编码失败保留旧偏好与正文。
    func saveTabSettings(_ settings: LanguageTabSettings) throws {
        let data = try JSONEncoder().encode(
            TabPreferencesArchive(
                format: 1,
                settings: settings
            )
        )
        guard data.count <= 512 * 1024 else {
            throw NateError.message("语言 Tab 完整配置超过 512 KiB。")
        }
        let domain = tabPreferences.defaults ?? .standard
        domain.set(data, forKey: "languageTabSettings")
        tabPreferences.loaded = true
        tabPreferences.settings = settings
        tabPreferences.warning = nil
        tabPreferences.sourceDomain = domain
        tabPreferences.sourceObject = domain.object(forKey: "languageTabSettings") as? NSObject
        tabPreferences.generation = UUID()
        applyCurrentTabSettings()
    }

    /// 业务作用：窗口采用独立标签布局，各实际正文视图按各自文档语言解析 Tab 配置。
    /// 参数说明: 无。
    /// 返回：仅改变新输入及显示规则，既有原文、选择身份、历史与保存点保持原状。
    func applyCurrentTabSettings() {
        let layout = currentDocumentTabLayout()
        let settings = currentTabSettings()
        let perDocument = Dictionary(
            uniqueKeysWithValues: documents.map {
                ($0.buffer.id, settings.settings(for: $0.language))
            }
        )
        for window in editorWindows {
            window.setDocumentTabLayout(layout)
            window.setTabSettings(perDocument)
        }
    }

    /// 业务作用：同时配置全局默认和当前语言覆盖，表单不得覆盖后来改变的实际偏好。
    /// 参数说明: 无。
    /// 返回：完整确认且来源未变时保存，取消、候选或配置失效时不改写偏好与正文。
    func showTabPreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentTabSettings()
        let runtime = tabPreferences, generation = tabPreferences.generation
        let domain = runtime.defaults ?? .standard
        let original = domain.object(forKey: "languageTabSettings") as? NSObject
        let language = active?.language ?? "normal"
        let name = registry?.language(language)?.name ?? language
        guard
            let settings = TabSettingsDialog.choose(
                initial: initial,
                language: language,
                name: name,
                warning: runtime.warning
            ), !closing
        else {
            return
        }
        let current = domain.object(forKey: "languageTabSettings") as? NSObject
        // 旧表单只拥有打开时的整份配置来源，偏好域或原字节改变后不能覆盖后来规则。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            original.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "Tab 配置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveTabSettings(settings)
            mainWindow?.status.stringValue = "Tab 设置已应用；已有文字、历史与保存状态保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "Tab 设置未保存：" + error.localizedDescription
        }
    }
}
