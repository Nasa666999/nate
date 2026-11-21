import AppKit
import NateSearch
import NateUI

@MainActor
final class SelectedTextHighlightPreferencesRuntime {
    var options = SelectedTextHighlightOptions()
    var generation = UUID()
    var defaults: UserDefaults?
    var failure: String?

    /// 业务作用：智能高亮设置独立于查找条件与文档，明确配置变化拥有独立身份。
    /// 参数说明: 无。
    /// 返回：默认偏好与尚未连接持久存储的运行期状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：恢复用户自己的智能高亮设置，损坏数据保留并说明失败，不阻止正文打开。
    /// 参数说明:
    /// - defaults: 当前应用使用的偏好存储。
    /// 返回：完整有效配置一次发布；缺少配置采用默认值，非法配置保留原数据与当前有效偏好。
    func loadSelectedTextHighlightOptions(from defaults: UserDefaults) {
        selectedTextPreferences.defaults = defaults
        guard defaults.object(forKey: "selectedTextHighlightOptions") != nil else {
            return
        }
        do {
            guard let data = defaults.data(forKey: "selectedTextHighlightOptions"), data.count <= 65_536
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            let options = try JSONDecoder().decode(SelectedTextHighlightOptions.self, from: data)
            selectedTextPreferences.options = options
            selectedTextPreferences.generation = UUID()
            selectedTextPreferences.failure = nil
        }
        catch {
            selectedTextPreferences.failure = "智能高亮设置无法恢复，原数据保留，当前使用有效偏好。"
        }
    }

    /// 业务作用：窗口只从仍属于本工作区的真实来源与目标视图取得智能高亮设置，旧窗口不再获得发布权。
    /// 参数说明:
    /// - target: 需要显示高亮的目标视图。
    /// - window: 当前实际工作区窗口。
    /// 返回：文档、窗口和目标均有效时提供完整偏好及适用查找身份，关闭或实例失效时为空。
    func selectedTextHighlightSettings(for target: EditorView, in window: EditorWindow)
        -> SelectedTextHighlightSettings?
    {
        guard !closing, mainWindow === window, let active, !active.closing,
            window.editor.document === active.buffer,
            documents.contains(where: {
                $0 === active
            }),
            documents.contains(where: {
                $0.buffer === target.document && !$0.closing
            })
        else {
            return nil
        }
        let options = selectedTextPreferences.options
        let find = findWindow?.options ?? searchSettingsState.options
        return SelectedTextHighlightSettings(
            options: options,
            generation: selectedTextPreferences.generation,
            findGeneration: options.useFindOptions ? findWindow?.configurationIdentity : nil,
            findCaseSensitive: options.useFindOptions && find.caseSensitive,
            findWholeWord: options.useFindOptions && find.wholeWord,
            wordBoundaries: window.editor.wordBoundaries
        )
    }

    /// 业务作用：搜索菜单直接提供智能高亮的全部独立选项，不通过持久颜色组模拟临时选择。
    /// 参数说明:
    /// - parent: 当前搜索主菜单。
    /// 返回：启用、大小写、整词、复用查找设置与另一视图五个可见开关。
    func addSelectedTextHighlightMenus(to parent: NSMenu) {
        let menu = NSMenu(title: "选中文本智能高亮")
        for (title, id) in [
            ("启用智能高亮", "smartHighlight"), ("区分大小写", "smartHighlightCase"),
            ("仅完整词", "smartHighlightWord"), ("使用查找窗口匹配选项", "smartHighlightFindOptions"),
            ("同时高亮另一视图", "smartHighlightOtherView"),
        ] {
            add(menu, title, id)
        }
        attach(menu, to: parent)
    }

    /// 业务作用：用户明确切换偏好先撤销旧身份，再刷新各视图；配置往返不能让旧匹配重新发布。
    /// 参数说明:
    /// - id: 五个固定智能高亮开关之一。
    /// 返回：匹配的动作保存并生效，未知标识不改变状态且返回假。
    @discardableResult
    func toggleSelectedTextHighlightOption(_ id: String) -> Bool {
        guard !closing else {
            return false
        }
        switch id {
        case "smartHighlight": selectedTextPreferences.options.enabled.toggle()
        case "smartHighlightCase": selectedTextPreferences.options.caseSensitive.toggle()
        case "smartHighlightWord": selectedTextPreferences.options.wholeWord.toggle()
        case "smartHighlightFindOptions": selectedTextPreferences.options.useFindOptions.toggle()
        case "smartHighlightOtherView": selectedTextPreferences.options.anotherView.toggle()
        default: return false
        }
        // 偏好身份必须先变更，刷新和持久化期间迟到的旧任务不能显示旧匹配。
        selectedTextPreferences.generation = UUID()
        do {
            let data = try JSONEncoder().encode(selectedTextPreferences.options)
            selectedTextPreferences.defaults?.set(data, forKey: "selectedTextHighlightOptions")
            selectedTextPreferences.failure = nil
        }
        catch {
            selectedTextPreferences.failure = "智能高亮设置未能保存，当前选择仅在本次运行生效。"
        }
        mainWindow?.refreshSelectedTextHighlights()
        refreshUI()
        return true
    }

    /// 业务作用：智能高亮菜单显示真实有效偏好，复用查找设置时避免独立开关暗示不同的实际匹配方式。
    /// 参数说明:
    /// - item: 当前菜单项。
    /// - id: 对应的固定智能高亮标识。
    /// 返回：属于该菜单时返回当前可用性，否则为空以继续其它验证。
    func validateSelectedTextHighlightMenu(_ item: NSMenuItem, id: String) -> Bool? {
        let options = selectedTextPreferences.options
        let find = findWindow?.options ?? searchSettingsState.options
        let checked: Bool
        switch id {
        case "smartHighlight": checked = options.enabled
        case "smartHighlightCase":
            checked = options.useFindOptions ? find.caseSensitive : options.caseSensitive
        case "smartHighlightWord": checked = options.useFindOptions ? find.wholeWord : options.wholeWord
        case "smartHighlightFindOptions": checked = options.useFindOptions
        case "smartHighlightOtherView": checked = options.anotherView
        default: return nil
        }
        item.state = checked ? .on : .off
        return !closing && (id == "smartHighlight" || options.enabled)
            && (!options.useFindOptions || !["smartHighlightCase", "smartHighlightWord"].contains(id))
    }
}
