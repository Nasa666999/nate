import AppKit
import NateCore
import NateUI

@MainActor
final class DelimiterSelectionRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = DelimiterSelectionSettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSObject?

    /// 业务作用：分隔符偏好独立持有完整归档来源，读取默认值不产生持久化。
    /// 参数说明: 无。
    /// 返回：默认行内圆括号和未读取的来源状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：读取有界分隔符配置，损坏或未知格式保留原归档并采用默认规则。
    /// 参数说明: 无。
    /// 返回：完整合法的配置快照，读取不会写回默认值。
    func currentDelimiterSelectionSettings() -> DelimiterSelectionSettings {
        let runtime = delimiterPreferences
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "delimiterSelectionSettings") as? NSObject
        if runtime.loaded, runtime.sourceDomain === domain,
            runtime.source.map({
                $0.isEqual(object)
            }) ?? (object == nil)
        {
            return runtime.settings
        }
        runtime.loaded = true
        runtime.sourceDomain = domain
        runtime.source = object
        runtime.generation = UUID()
        runtime.settings = DelimiterSelectionSettings()
        runtime.warning = nil
        if let object {
            do {
                guard let data = object as? Data, data.count <= 4096 else {
                    throw NateError.message("分隔符设置不是 4 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(DelimiterSelectionPreferenceValue.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("分隔符设置格式无法识别。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "分隔符设置未读取，原归档保留；本次使用默认规则。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：显式应用完整分隔符配置后同步全部克隆，不改变既有正文、选择和历史。
    /// 参数说明:
    /// - settings: 两端字符及扫描范围均已验证的完整配置。
    /// 返回：关闭或编码失败不保存；成功时先更新偏好来源，再同步所有视图规则。
    func saveDelimiterSelectionSettings(_ settings: DelimiterSelectionSettings) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，分隔符设置未保存。")
        }
        let data = try JSONEncoder().encode(DelimiterSelectionPreferenceValue(format: 1, settings: settings))
        guard data.count <= 4096 else {
            throw NateError.message("完整分隔符设置超过 4 KiB。")
        }
        let runtime = delimiterPreferences
        let domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "delimiterSelectionSettings")
        runtime.loaded = true
        runtime.settings = settings
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.source = data as NSData
        runtime.generation = UUID()
        mainWindow?.setDelimiterSelectionSettings(settings)
    }

    /// 业务作用：表单应用前复验原偏好域和字节来源，防止旧草稿覆盖外部更改。
    /// 参数说明: 无。
    /// 返回：明确应用且来源仍有效时保存；取消、关闭或失权保留当前配置。
    func showDelimiterSelectionPreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentDelimiterSelectionSettings()
        let runtime = delimiterPreferences
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = domain.object(forKey: "delimiterSelectionSettings") as? NSObject
        guard let selected = DelimiterSelectionDialog.choose(initial: initial, warning: runtime.warning),
            !closing
        else {
            return
        }
        let current = domain.object(forKey: "delimiterSelectionSettings") as? NSObject
        // 相同配置往返、域切换和字节变化均不能恢复打开旧表单时的写入权限。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            source.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "分隔符设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveDelimiterSelectionSettings(selected)
            mainWindow?.status.stringValue = "分隔符选择规则已应用，已有正文和选区保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "分隔符设置未保存：" + error.localizedDescription
        }
    }
}

private struct DelimiterSelectionPreferenceValue: Codable {
    let format: Int
    let settings: DelimiterSelectionSettings
}
