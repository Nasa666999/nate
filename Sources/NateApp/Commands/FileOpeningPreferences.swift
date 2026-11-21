import AppKit
import NateCore
import NateUI

@MainActor
final class FileOpeningPreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = FileOpeningSettings()
    var warning: String?
    var recentWarning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSObject?

    /// 业务作用：文件偏好持有独立来源，读取默认值不授予覆盖原归档的权限。
    /// 参数说明: 无。
    /// 返回：默认偏好与未读取的来源状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：有界读取新建与文件入口偏好，损坏或未知格式保留原数据并采用默认行为。
    /// 参数说明: 无。
    /// 返回：当前来源对应的完整设置；读取不访问目录或写入偏好。
    func currentFileOpeningSettings() -> FileOpeningSettings {
        let runtime = fileOpeningPreferences
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "fileOpeningSettings") as? NSObject
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
        runtime.settings = FileOpeningSettings()
        runtime.warning = nil
        if let object {
            do {
                guard let data = object as? Data, data.count <= 131_072 else {
                    throw NateError.message("文件偏好不是 128 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(FileOpeningPreferenceValue.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("文件偏好格式无法识别。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "文件偏好未读取，原归档保留；本次采用默认设置。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：明确应用完整偏好后发布新来源，已有正文、选区和文档格式保持原状态。
    /// 参数说明:
    /// - settings: 已完整验证的文件偏好。
    /// 返回：关闭或容量失败不写入；成功后更新缓存及最近文件菜单。
    func saveFileOpeningSettings(_ settings: FileOpeningSettings) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，文件偏好未保存。")
        }
        let data = try JSONEncoder().encode(FileOpeningPreferenceValue(format: 1, settings: settings))
        guard data.count <= 131_072 else {
            throw NateError.message("完整文件偏好超过 128 KiB。")
        }
        let runtime = fileOpeningPreferences
        let domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "fileOpeningSettings")
        runtime.settings = settings
        runtime.loaded = true
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.source = data as NSData
        runtime.generation = UUID()
        buildMenus()
    }

    /// 业务作用：文件偏好表单只有原域、原归档和原代次仍有效时才能保存完整草稿。
    /// 参数说明: 无。
    /// 返回：明确应用且来源未变时保存，取消、关闭或来源变化均保留当前偏好。
    func showFileOpeningPreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentFileOpeningSettings()
        let runtime = fileOpeningPreferences
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = domain.object(forKey: "fileOpeningSettings") as? NSObject
        let languages = (registry?.languages ?? []).filter {
            $0.id != "searchResult"
        }.map {
            (id: $0.id, name: $0.name)
        }
        guard
            let selected = FileOpeningDialog.choose(
                initial: initial,
                languages: languages,
                warning: runtime.warning ?? runtime.recentWarning
            ), !closing
        else {
            return
        }
        let current = domain.object(forKey: "fileOpeningSettings") as? NSObject
        // 旧草稿不能覆盖后来配置，即使中途往返到相同值，也须重新取得完整来源。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            source.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "文件偏好已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveFileOpeningSettings(selected)
            mainWindow?.status.stringValue = "文件偏好已保存，默认语言与换行用于以后新建的文档。"
        }
        catch {
            mainWindow?.status.stringValue = "文件偏好未保存：" + error.localizedDescription
        }
    }
}

private struct FileOpeningPreferenceValue: Codable {
    let format: Int
    let settings: FileOpeningSettings
}
