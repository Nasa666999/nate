import AppKit
import NateCore
import NateUI

@MainActor
final class DateTimePreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = DateTimeSettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSObject?

    /// 业务作用：日期时间偏好独立于输入和宏持有来源，未读取时不保存默认值。
    /// 参数说明: 无。
    /// 返回：默认格式、次序和未读取的归档来源。
    init() {}
}

extension ApplicationController {
    /// 业务作用：有界读取完整日期时间格式，损坏或未知归档保持原字节并回退默认值。
    /// 参数说明: 无。
    /// 返回：全部验证成功的完整设置；读取不产生任何持久化写入。
    func currentDateTimeSettings() -> DateTimeSettings {
        let runtime = dateTimePreferences
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "dateTimeSettings") as? NSObject
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
        runtime.settings = DateTimeSettings()
        runtime.warning = nil
        if let object {
            do {
                guard let data = object as? Data, data.count <= 4096 else {
                    throw NateError.message("日期时间设置不是 4 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(DateTimePreferenceValue.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("日期时间设置格式无法识别。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "日期时间设置未读取，原归档保留；本次使用默认格式。" + error.localizedDescription
            }
        }
        return runtime.settings
    }

    /// 业务作用：明确应用后保存完整格式，现有正文和已记录的宏输入文字不被重写。
    /// 参数说明:
    /// - settings: 已完整解析的格式和短长次序。
    /// 返回：关闭或归档失败不保存；成功时发布完整偏好及新来源身份。
    func saveDateTimeSettings(_ settings: DateTimeSettings) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，日期时间格式未保存。")
        }
        _ = try settings.formatted(date: Date(), mode: .custom)
        let data = try JSONEncoder().encode(DateTimePreferenceValue(format: 1, settings: settings))
        guard data.count <= 4096 else {
            throw NateError.message("完整日期时间设置超过 4 KiB。")
        }
        let runtime = dateTimePreferences
        let domain = runtime.defaults ?? .standard
        domain.set(data, forKey: "dateTimeSettings")
        runtime.settings = settings
        runtime.loaded = true
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.source = data as NSData
        runtime.generation = UUID()
    }

    /// 业务作用：表单只有原偏好域与原字节来源仍一致时才能覆盖配置。
    /// 参数说明: 无。
    /// 返回：完整有效且明确应用时保存；取消、关闭或来源改变均保留当前配置。
    func showDateTimePreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentDateTimeSettings()
        let runtime = dateTimePreferences
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = domain.object(forKey: "dateTimeSettings") as? NSObject
        guard let selected = DateTimeDialog.choose(initial: initial, warning: runtime.warning), !closing
        else {
            return
        }
        let current = domain.object(forKey: "dateTimeSettings") as? NSObject
        // 草稿不拥有覆盖后来配置的权限，值相同的往返也必须重新打开表单。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            source.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "日期时间设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveDateTimeSettings(selected)
            mainWindow?.status.stringValue = "日期时间格式已保存，已有正文保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "日期时间格式未保存：" + error.localizedDescription
        }
    }
}

private struct DateTimePreferenceValue: Codable {
    let format: Int
    let settings: DateTimeSettings
}
