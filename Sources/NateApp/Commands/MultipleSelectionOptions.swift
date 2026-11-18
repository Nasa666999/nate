import AppKit
import NateSearch

extension ApplicationController {
    /// 业务作用：恢复多选独立匹配选项，未知或损坏设置不能替代当前有效条件。
    /// 参数说明:
    /// - defaults: 当前应用所选的偏好存储。
    /// 返回：完整有效配置一次生效；读取失败保留原数据并说明当前使用默认偏好。
    func loadMultipleSelectionOptions(from defaults: UserDefaults) {
        let runtime = multipleSelection
        runtime.defaults = defaults
        guard defaults.object(forKey: "multipleSelectionOptions") != nil else {
            return
        }
        do {
            guard let data = defaults.data(forKey: "multipleSelectionOptions"), data.count <= 4096 else {
                throw CocoaError(.coderReadCorrupt)
            }
            runtime.options = try JSONDecoder().decode(MultipleSelectionOptions.self, from: data)
            cancelMultipleSelection()
            runtime.failure = nil
        }
        catch {
            runtime.failure = "多选匹配设置无法恢复，原数据保留，当前使用有效偏好。"
        }
    }

    /// 业务作用：多选大小写与全词开关独立持久化，配置往返撤销旧选择计划与原文序列。
    /// 参数说明:
    /// - id: 区分大小写或整词的固定菜单标识。
    /// 返回：当前明确选择生效并保存；编码失败保留本次有效偏好并说明未持久化。
    func toggleMultipleSelectionOption(_ id: String) {
        guard !closing else {
            return
        }
        switch id {
        case "multipleSelectionCase": multipleSelection.options.caseSensitive.toggle()
        case "multipleSelectionWord": multipleSelection.options.wholeWord.toggle()
        default: return
        }
        // 配置改变先撤销发布资格，迟到计算不能因选项恢复原值而改写光标。
        cancelMultipleSelection()
        do {
            let data = try JSONEncoder().encode(multipleSelection.options)
            multipleSelection.defaults?.set(data, forKey: "multipleSelectionOptions")
            multipleSelection.failure = nil
        }
        catch {
            multipleSelection.failure = "多选匹配设置尚未保存，当前选项仅在本次运行生效。"
        }
        refreshUI()
    }

    /// 业务作用：多选菜单反映真实编辑焦点、输入保护和独立匹配选项，不以当前查询窗口代替正文上下文。
    /// 参数说明:
    /// - item: 当前验证的原生菜单项。
    /// - id: 稳定多选动作或选项标识。
    /// 返回：多选菜单提供实际可用性，其它菜单为空。
    func validateMultipleSelectionMenu(_ item: NSMenuItem, id: String) -> Bool? {
        switch id {
        case "multipleSelectionCase", "multipleSelectionWord":
            item.state =
                (id == "multipleSelectionCase"
                    ? multipleSelection.options.caseSensitive : multipleSelection.options.wholeWord)
                ? .on : .off
            return !closing
        case "cancelMultipleSelection": return multipleSelection.task != nil
        case "removeMatchSelection": return (quickFindContext()?.2.viewSelections.count ?? 0) > 1
        case "selectMatches", "addMatch", "skipMatch": return quickFindContext() != nil
        default: return nil
        }
    }
}
