import AppKit
import NateCore
import NateUI

@MainActor
final class WordBoundaryRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings = WordBoundarySettings()
    var warning: String?
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var source: NSObject?

    /// 业务作用：词规则偏好独立于搜索请求持有来源，读取之前不保存默认值。
    /// 参数说明: 无。
    /// 返回：没有附加词字符及来源权限的独立状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：完整读取全局词规则，损坏或未知归档保留原值并使用默认分类。
    /// 参数说明: 无。
    /// 返回：有界且合法的规则快照，读取不产生偏好写入。
    func currentWordBoundaries() -> WordBoundarySettings {
        let runtime = wordPreferences
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "wordBoundarySettings") as? NSObject
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
        runtime.settings = WordBoundarySettings()
        runtime.warning = nil
        if let object {
            do {
                guard let data = object as? Data, data.count <= 4096 else {
                    throw NateError.message("词边界设置不是 4 KiB 以内的完整归档。")
                }
                let archive = try JSONDecoder().decode(WordBoundaryPreferenceValue.self, from: data)
                guard archive.format == 1 else {
                    throw NateError.message("词边界设置格式无法识别。")
                }
                runtime.settings = archive.settings
            }
            catch {
                runtime.warning = "词规则未被读取，原归档保留；本次使用默认词字符。" + error.localizedDescription
            }
        }
        return runtime.settings
    }
}
