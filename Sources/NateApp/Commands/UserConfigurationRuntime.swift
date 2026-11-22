import AppKit
import CoreFoundation
import NateCore
import NateUI

@MainActor
final class UserConfigurationRuntime {
    var defaults: UserDefaults?
    var domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let io = IOExecutor(name: "io.github.nate.user-configuration", concurrency: 1, maximumStalled: 2)
    var task: Task<Void, Never>?
    var operation: UUID?
    var generation = UUID()
    var preview: UserConfiguration?
    var previewName: String?
    var source: UserConfiguration?
    var sourceDomain: UserDefaults?
    var previewWindow: NSWindow?
    var previewGeneration: UUID?
    var sourceGenerations: [UUID] = []
    var failure: String?
    var searchWarning: String?

    /// 业务作用：配置只读候选与实际偏好分别持有来源，尚未确认的导入不取得写入资格。
    /// 参数说明: 无。
    /// 返回：没有待执行动作或导入预览的独立运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：应用的配置迁移统一使用同一偏好域，系统窗口位置和独立资源仍由自己的存储管理。
    /// 参数说明: 无。
    /// 返回：当前明确连接的应用偏好域，未连接时使用标准域。
    func configurationDefaults() -> UserDefaults {
        userConfiguration.defaults ?? .standard
    }

    /// 业务作用：启动或切换偏好来源时统一连接各编辑组件，旧导入候选随来源变更失去发布权。
    /// 参数说明:
    /// - domain: 本次完整用户配置所属的偏好域。
    /// 返回：所有偏好读取使用同一域，不读取文件、加载历史或保存默认值。
    func connectConfigurationDefaults(_ domain: UserDefaults) {
        userConfiguration.generation = UUID()
        userConfiguration.defaults = domain
        displayPreferences.defaults = domain
        tabPreferences.defaults = domain
        indentationPreferences.defaults = domain
        pairPreferences.defaults = domain
        wordPreferences.defaults = domain
        delimiterPreferences.defaults = domain
        dateTimePreferences.defaults = domain
        fileOpeningPreferences.defaults = domain
        webSearch.defaults = domain
        printing.defaults = domain
        textTools.hexDefaults = domain
        selectedTextPreferences.defaults = domain
        multipleSelection.defaults = domain
        clipboardDefaults = domain
        incrementalDefaults = domain
    }

    /// 业务作用：原生表单的业务代次共同约束配置导入，同值往返的已知设置动作也不能被旧预览覆盖。
    /// 参数说明: 无。
    /// 返回：当前可解释的偏好代次，不触发读取或持久化。
    func configurationGenerationProof() -> [UUID] {
        var values = [
            displayPreferences.generation, tabPreferences.generation, indentationPreferences.generation,
            pairPreferences.generation, wordPreferences.generation, delimiterPreferences.generation,
            dateTimePreferences.generation, fileOpeningPreferences.generation, webSearch.generation,
            printing.generation, selectedTextPreferences.generation,
        ]
        if let findWindow {
            values.append(findWindow.configurationIdentity)
        }
        return values
    }

    /// 业务作用：配置来源只捕获白名单字段及原类型，未设置与显式默认值不会被自动合并。
    /// 参数说明: 无。
    /// 返回：完整受限来源快照；不支持的存储类型或过量字段拒绝捕获，不重写原偏好。
    func configurationSource() throws -> UserConfiguration {
        let domain = configurationDefaults()
        let entries = try UserConfigurationSchema.keys.map {
            key in
            try UserPreferenceEntry(key: key, value: Self.configurationValue(domain.object(forKey: key)))
        }
        return try UserConfiguration(entries: entries)
    }

    /// 业务作用：导出固定当前完整偏好，搜索窗口只提供行为设置，查询和历史不混入配置包。
    /// 参数说明: 无。
    /// 返回：全部白名单字段及语义合法的配置；原存储损坏时拒绝导出默认值冒充原设置。
    func exportableUserConfiguration() throws -> UserConfiguration {
        var entries = try configurationSource().entries
        if let index = entries.firstIndex(where: {
            $0.key == "searchUserPreferences"
        }) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var previous: SearchUserPreferences?
            if case .unset = entries[index].value {
                previous = nil
            }
            else {
                // 当前界面不能掩盖无法解释的原配置，导出前先确认原存储仍属于已知格式。
                try UserConfigurationSchema.validate(entries[index])
                if case .bytes(let data) = entries[index].value {
                    previous = try SearchUserPreferences.decode(data)
                }
            }
            let preferences = SearchUserPreferences(
                state: findWindow?.state ?? mergingSearchUserPreferences(searchSettingsState)
            )
            try preferences.validate()
            let data = try encoder.encode(preferences)
            if try previous.map({ try encoder.encode($0) }) != data {
                entries[index] = try UserPreferenceEntry(
                    key: "searchUserPreferences",
                    value: .bytes(data)
                )
            }
        }
        let result = try UserConfiguration(entries: entries)
        try UserConfigurationSchema.validate(result)
        return result
    }

    /// 业务作用：原生偏好值保留实际布尔和数值类型，不能依赖宽松转换把损坏字段改成另一项合法值。
    /// 参数说明:
    /// - object: 当前偏好键的完整原始对象，为空表示未设置。
    /// 返回：可完整保存的类型值；不支持的类型、越界整数或单项超量整体拒绝。
    private static func configurationValue(_ object: Any?) throws -> UserPreferenceValue {
        guard let object else {
            return .unset
        }
        let result: UserPreferenceValue
        if let data = object as? Data {
            result = .bytes(data)
        }
        else if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                result = .boolean(number.boolValue)
            }
            else if ["f", "d"].contains(String(cString: number.objCType)) {
                result = .decimal(number.doubleValue)
            }
            else if let integer = Int64(number.stringValue) {
                result = .integer(integer)
            }
            else {
                throw NateError.message("当前用户配置整数超出完整可表示范围。")
            }
        }
        else if let text = object as? String {
            result = .text(text)
        }
        else {
            throw NateError.message("当前用户配置含不受支持的存储类型，请先检查相应偏好。")
        }
        try result.validate()
        return result
    }
}
