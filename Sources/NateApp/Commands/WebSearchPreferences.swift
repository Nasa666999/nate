import AppKit
import NateCore
import NateUI

@MainActor
final class WebSearchRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = WebSearchSettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSObject?
    var openURL: @MainActor (URL) -> Bool

    /// 业务作用：网络偏好与明确网址打开共用独立运行上下文，默认只在调用时交给系统浏览器。
    /// 参数说明: 无。
    /// 返回：未读取偏好和未执行任何网络动作的运行状态。
    init() {
        openURL = {
            NSWorkspace.shared.open($0)
        }
    }
}

extension ApplicationController {
    /// 业务作用：有界读取完整搜索引擎配置，损坏或未知格式保留原数据且不触发联网。
    /// 参数说明: 无。
    /// 返回：当前来源对应的有效设置；缺失或失败时采用默认引擎并保留原因。
    func currentWebSearchSettings() -> WebSearchSettings {
        let runtime = webSearch
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "webSearchSettings") as? NSObject
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
        runtime.settings = WebSearchSettings()
        runtime.warning = nil
        if let object {
            do {
                guard let data = object as? Data, data.count <= 32_768 else {
                    throw NateError.message("搜索引擎设置不是 32 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(WebSearchPreferenceValue.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("搜索引擎设置格式无法识别。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "搜索引擎设置未读取，原归档保留；本次采用默认引擎。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：明确应用完整搜索引擎草稿只保存偏好，不以保存动作打开浏览器。
    /// 参数说明:
    /// - settings: 已完整验证的引擎与原模板。
    /// 返回：关闭或容量不足不写入，成功时更新完整缓存与来源代次。
    func saveWebSearchSettings(_ settings: WebSearchSettings) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，搜索引擎设置未保存。")
        }
        let data = try JSONEncoder().encode(WebSearchPreferenceValue(format: 1, settings: settings))
        guard data.count <= 32_768 else {
            throw NateError.message("完整搜索引擎设置超过 32 KiB。")
        }
        let runtime = webSearch
        let domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "webSearchSettings")
        runtime.settings = settings
        runtime.loaded = true
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.source = data as NSData
        runtime.generation = UUID()
    }

    /// 业务作用：设置表单只在原域、原配置和原代次仍成立时发布，取消或变化不覆盖后来偏好。
    /// 参数说明: 无。
    /// 返回：合法草稿明确应用后保存，失效表单保留当前来源并提示重新打开。
    func showWebSearchPreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentWebSearchSettings()
        let runtime = webSearch
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = domain.object(forKey: "webSearchSettings") as? NSObject
        guard let selected = WebSearchDialog.choose(initial: initial, warning: runtime.warning), !closing
        else {
            return
        }
        let current = domain.object(forKey: "webSearchSettings") as? NSObject
        // 相同值的往返也不能把旧草稿变成新配置的覆盖授权。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            source.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "搜索引擎设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveWebSearchSettings(selected)
            mainWindow?.status.stringValue = "搜索引擎设置已保存；预览和配置读取不会访问网络。"
        }
        catch {
            mainWindow?.status.stringValue = "搜索引擎设置未保存：" + error.localizedDescription
        }
    }
}

private struct WebSearchPreferenceValue: Codable {
    let format: Int
    let settings: WebSearchSettings
}
