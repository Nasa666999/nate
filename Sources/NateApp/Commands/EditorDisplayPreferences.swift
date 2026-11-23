import AppKit
import NateCore
import NateUI

@MainActor
final class EditorDisplayPreferencesRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var sourceValid = true
    var settings = EditorDisplaySettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSDictionary?

    /// 业务作用：显示偏好与正文恢复分别持有状态，尚未读取时不写入默认配置。
    /// 参数说明: 无。
    /// 返回：没有取得偏好来源权限的独立运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：显示及旧式偏好共同形成来源身份，模态表单不能覆盖后来改变的任一显示选项。
    /// 参数说明:
    /// - domain: 当前明确偏好域。
    /// 返回：新旧显示字段及自动保存开关的完整只读来源证据。
    func displayPreferenceSource(_ domain: UserDefaults) -> NSDictionary {
        var values: [String: Any] = [:]
        for key in ["editorDisplaySettings", "fontSize", "wrapLines", "showSymbols", "autosaveEnabled"] {
            values[key] = domain.object(forKey: key) ?? NSNull()
        }
        return values as NSDictionary
    }

    /// 业务作用：恢复完整显示设置或迁移旧式显示值，不能解释的原配置保留并采用安全默认。
    /// 参数说明: 无。
    /// 返回：完整合法配置及持续说明，不因读取设置而重写损坏或未知归档。
    func currentDisplaySettings() -> EditorDisplaySettings {
        let runtime = displayPreferences
        let domain = runtime.defaults ?? .standard
        let source = displayPreferenceSource(domain)
        if runtime.loaded, runtime.sourceDomain === domain, runtime.source?.isEqual(source) == true {
            return runtime.settings
        }
        runtime.loaded = true
        runtime.sourceDomain = domain
        runtime.source = source
        runtime.generation = UUID()
        runtime.settings = EditorDisplaySettings()
        runtime.warning = nil
        runtime.sourceValid = true
        if let object = domain.object(forKey: "editorDisplaySettings") {
            do {
                guard let data = object as? Data, data.count <= 4096 else {
                    throw NateError.message("显示设置不是 4 KiB 以内的完整归档。")
                }
                runtime.settings = try JSONDecoder().decode(EditorDisplaySettings.self, from: data)
            }
            catch {
                runtime.sourceValid = false
                runtime.warning = "显示配置未被读取，原值保留，本次采用默认显示。" + error.localizedDescription
            }
        }
        else {
            let size = domain.double(forKey: "fontSize")
            runtime.settings =
                (try? EditorDisplaySettings(
                    fontName: nil,
                    fontSize: size.isFinite && (7...72).contains(size) ? size : 13,
                    appearance: .system,
                    wrapLines: domain.bool(forKey: "wrapLines"),
                    showSymbols: domain.bool(forKey: "showSymbols")
                )) ?? EditorDisplaySettings()
        }
        return runtime.settings
    }

    /// 业务作用：启动时统一恢复显示与自动保存开关，字体缺失只回退呈现，不丢弃配置中的原名称。
    /// 参数说明:
    /// - window: 已完成正文恢复且尚未显示的主窗口。
    /// 返回：主视图采用完整配置，损坏设置不阻止打开已有正文。
    func loadEditorPreferences(into window: EditorWindow) {
        let domain = displayPreferences.defaults ?? .standard
        autosaveEnabled =
            domain.object(forKey: "autosaveEnabled") == nil || domain.bool(forKey: "autosaveEnabled")
        applyDisplaySettings(currentDisplaySettings(), to: window)
        window.setEditorTheme(themePreferences.compiled)
    }

    /// 业务作用：字体与外观只改变呈现，当前不可用字体保留身份并回退到系统等宽字体。
    /// 参数说明:
    /// - settings: 当前完整合法配置。
    /// - window: 需要同步全部克隆的窗口。
    /// 返回：外观和所有视图同步生效，正文、历史和保存状态不被改变。
    func applyDisplaySettings(_ settings: EditorDisplaySettings, to window: EditorWindow?) {
        let font =
            settings.fontName.flatMap {
                NSFont(name: $0, size: CGFloat(settings.fontSize))
            }
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize), weight: .regular)
        if let name = settings.fontName, NSFont(name: name, size: CGFloat(settings.fontSize)) == nil {
            displayPreferences.warning = "字体当前不可用，已采用系统等宽字体；原字体名称仍保留：" + name
        }
        switch settings.appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        window?.setDisplayOptions(
            font: font,
            wrapLines: settings.wrapLines,
            showSymbols: settings.showSymbols
        )
    }
}
