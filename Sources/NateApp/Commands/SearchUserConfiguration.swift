import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：独立用户偏好覆盖搜索行为，旧搜索归档继续保留查询、目录、历史和当前页面。
    /// 参数说明:
    /// - state: 当前有效或刚从磁盘读取的完整搜索状态。
    /// 返回：合并后的完整状态；未知或损坏偏好保持原数据和原状态，不阻止编辑器打开。
    func mergingSearchUserPreferences(_ state: SearchWindowState) -> SearchWindowState {
        let domain = configurationDefaults()
        guard let object = domain.object(forKey: "searchUserPreferences") else {
            userConfiguration.searchWarning = nil
            return state
        }
        do {
            guard let data = object as? Data, data.count <= 65_536 else {
                throw NateError.message("搜索用户偏好不是完整的 64 KiB 以内归档。")
            }
            let preferences = try SearchUserPreferences.decode(data)
            userConfiguration.searchWarning = nil
            return preferences.applying(to: state)
        }
        catch {
            userConfiguration.searchWarning = "搜索用户偏好未读取，原数据保留：" + error.localizedDescription
            return state
        }
    }

    /// 业务作用：普通搜索控件变化只保存行为偏好，查询与历史不会写入通用用户配置键。
    /// 参数说明:
    /// - state: 当前完整搜索窗口状态，只有独立偏好字段会被提取。
    /// - replacingUnknown: 用户明确重建搜索设置时允许替换无法解释的偏好。
    /// 返回：完整合法偏好保存或保持相同原字节；未知原格式未获重建授权时保留并说明原因。
    func persistSearchUserPreferences(_ state: SearchWindowState, replacingUnknown: Bool = false) {
        let domain = configurationDefaults()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var previous: SearchUserPreferences?
            if let object = domain.object(forKey: "searchUserPreferences"), !replacingUnknown {
                // 普通查询变化不能顺带重建损坏或未来格式的独立偏好。
                guard let data = object as? Data, data.count <= 65_536 else {
                    throw NateError.message("原搜索用户偏好类型或容量无法解释。")
                }
                previous = try SearchUserPreferences.decode(data)
            }
            let preferences = SearchUserPreferences(state: state)
            try preferences.validate()
            let data = try encoder.encode(preferences)
            guard data.count <= 65_536 else {
                throw NateError.message("完整搜索用户偏好超过 64 KiB。")
            }
            // 查询和历史的变化不改变独立行为偏好，也不重排原文件的合法 JSON 字节。
            if let previous, try encoder.encode(previous) == data {
                userConfiguration.searchWarning = nil
                return
            }
            if domain.data(forKey: "searchUserPreferences") != data {
                domain.set(data, forKey: "searchUserPreferences")
            }
            userConfiguration.searchWarning = nil
        }
        catch {
            userConfiguration.searchWarning = "搜索用户偏好未保存，原数据保留：" + error.localizedDescription
        }
    }
}
