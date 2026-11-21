import AppKit
import NateCore
import NateUI

private struct IndentationPreferencesArchive: Codable {
    let format: Int
    let settings: IndentationSettings
}

@MainActor
final class IndentationPreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = IndentationSettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var sourceObject: NSObject?

    /// 业务作用：输入策略独立于正文和恢复内容，偏好异常不取得文件或选择的修改权。
    /// 参数说明: 无。
    /// 返回：尚未读取偏好、默认继承缩进且逐字退格的独立运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：完整读取自动缩进与退格选项，损坏或未知设置保留原值并显示默认策略。
    /// 参数说明: 无。
    /// 返回：当前完整配置，不在读取或启动期间自动重写未能解释的归档。
    func currentIndentationSettings() -> IndentationSettings {
        let runtime = indentationPreferences, domain = runtimeDomainForIndentation()
        let object = domain.object(forKey: "indentationSettings") as? NSObject
        if runtime.loaded, runtime.sourceDomain === domain,
            runtime.sourceObject.map({
                $0.isEqual(object)
            }) ?? (object == nil)
        {
            return runtime.settings
        }
        runtime.loaded = true
        runtime.settings = IndentationSettings()
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.sourceObject = object
        runtime.generation = UUID()
        if let object {
            do {
                guard let data = object as? Data, data.count <= 1024 else {
                    throw NateError.message("自动缩进设置不是 1 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(IndentationPreferencesArchive.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("自动缩进设置格式尚不受支持。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "自动缩进设置未被读取，原归档保留；本次继承原缩进并逐字退格。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：保存完整输入策略后同步当前克隆，既有正文和格式参数保持原状。
    /// 参数说明:
    /// - settings: 用户明确应用的完整自动缩进与退格规则。
    /// 返回：完整编码成功后保存并生效，容量或编码失败保留原设置。
    func saveIndentationSettings(_ settings: IndentationSettings) throws {
        let data = try JSONEncoder().encode(
            IndentationPreferencesArchive(
                format: 1,
                settings: settings
            )
        )
        guard data.count <= 1024 else {
            throw NateError.message("自动缩进完整配置超过 1 KiB。")
        }
        let runtime = indentationPreferences, domain = runtimeDomainForIndentation()
        domain.set(data, forKey: "indentationSettings")
        runtime.loaded = true
        runtime.settings = settings
        runtime.warning = nil
        runtime.sourceDomain = domain
        // 缓存绑定本次完整编码，外部写入的新归档必须重新复验，不能冒充当前内存规则。
        runtime.sourceObject = data as NSData
        runtime.generation = UUID()
        mainWindow?.setIndentationSettings(settings)
    }

    /// 业务作用：独立原生设置表单只改变后续按键策略，不能确认候选或覆盖后来修改的偏好。
    /// 参数说明: 无。
    /// 返回：完整确认且原偏好来源未变时应用，取消、候选和旧草稿保持原状态。
    func showIndentationPreferences() {
        // 候选仍归输入法持有，配置窗口不能借焦点转移提前确认尚未提交的正文。
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentIndentationSettings()
        let runtime = indentationPreferences, generation = indentationPreferences.generation
        let domain = runtimeDomainForIndentation()
        let original = domain.object(forKey: "indentationSettings") as? NSObject
        guard let selected = IndentationSettingsDialog.choose(initial: initial, warning: runtime.warning),
            !closing
        else {
            return
        }
        let current = domain.object(forKey: "indentationSettings") as? NSObject
        // 旧表单只拥有打开时的配置来源，偏好域或原字节改变后不能把后来规则覆盖成旧草稿。
        guard runtime.generation == generation, runtimeDomainForIndentation() === domain,
            original.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "自动缩进设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveIndentationSettings(selected)
            mainWindow?.status.stringValue = "自动缩进与退格规则已应用，已有正文和历史保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "自动缩进设置未保存：" + error.localizedDescription
        }
    }

    /// 业务作用：读取与保存采用同一实际偏好域，独立工作区的设置来源不被中途替换。
    /// 参数说明: 无。
    /// 返回：当前配置明确使用的偏好域，不读取或写入其它来源。
    private func runtimeDomainForIndentation() -> UserDefaults {
        indentationPreferences.defaults ?? .standard
    }
}
