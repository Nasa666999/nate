import AppKit
import NateCore
import NateUI

private struct PairPreferencesArchive: Codable {
    let format: Int
    let settings: PairInsertionSettings
}

@MainActor
final class PairPreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = PairInsertionSettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var sourceObject: NSObject?

    /// 业务作用：配对策略独立于正文恢复状态，尚未读取偏好时保留字面输入行为。
    /// 参数说明: 无。
    /// 返回：尚未取得偏好来源的独立状态，不写入默认值。
    init() {}
}

extension ApplicationController {
    /// 业务作用：完整读取配对偏好，损坏或未知内容保留原值并关闭自动输入辅助。
    /// 参数说明: 无。
    /// 返回：当前完整规则，读取期间不重写不能解释的归档。
    func currentPairSettings() -> PairInsertionSettings {
        let runtime = pairPreferences, domain = pairPreferences.defaults ?? .standard
        let object = domain.object(forKey: "pairInsertionSettings") as? NSObject
        if runtime.loaded, runtime.sourceDomain === domain,
            runtime.sourceObject.map({
                $0.isEqual(object)
            }) ?? (object == nil)
        {
            return runtime.settings
        }
        runtime.loaded = true
        runtime.settings = PairInsertionSettings()
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.sourceObject = object
        runtime.generation = UUID()
        if let object {
            do {
                guard let data = object as? Data, data.count <= 32_768 else {
                    throw NateError.message("配对设置不是 32 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(PairPreferencesArchive.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("配对设置格式尚不受支持。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "配对设置未被读取，原归档保留；本次关闭自动配对。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：用户明确应用后完整保存配对定义，并同步现有克隆的后续输入策略。
    /// 参数说明:
    /// - settings: 已完整验证的开关、全部定义和闭合越过规则。
    /// 返回：编码和容量均满足时写入；失败不改变原偏好、正文或视图配置。
    func savePairSettings(_ settings: PairInsertionSettings) throws {
        let data = try JSONEncoder().encode(
            PairPreferencesArchive(
                format: 1,
                settings: settings
            )
        )
        guard data.count <= 32_768 else {
            throw NateError.message("完整配对设置超过 32 KiB。")
        }
        let runtime = pairPreferences, domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "pairInsertionSettings")
        runtime.loaded = true
        runtime.settings = settings
        runtime.warning = nil
        runtime.sourceDomain = domain
        // 缓存绑定本次明确编码，写入期间出现的外部新值须在下次读取时重新验证。
        runtime.sourceObject = data as NSData
        runtime.generation = UUID()
        mainWindow?.setPairInsertionSettings(settings)
    }

    /// 业务作用：配对表单只编辑偏好草稿，不能确认输入法候选或覆盖后来改变的配置来源。
    /// 参数说明: 无。
    /// 返回：明确应用且来源身份仍一致时保存完整设置，取消或失去来源资格时保留原值。
    func showPairPreferences() {
        // 配置窗口不能借焦点转移消费候选，原输入法仍持有未提交文字。
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentPairSettings(), runtime = pairPreferences
        let generation = runtime.generation, domain = runtime.defaults ?? .standard
        let original = domain.object(forKey: "pairInsertionSettings") as? NSObject
        guard let selected = PairSettingsDialog.choose(initial: initial, warning: runtime.warning), !closing
        else {
            return
        }
        let current = domain.object(forKey: "pairInsertionSettings") as? NSObject
        // 表单只拥有打开时的偏好来源，域切换、明确保存或原字节变化后不能发布旧草稿。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            original.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "配对设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try savePairSettings(selected)
            mainWindow?.status.stringValue = "完整配对规则已应用，既有正文与历史保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "配对设置未保存：" + error.localizedDescription
        }
    }
}
