import Foundation
import NateCore
import NateSearch

public struct SearchWindowState: Codable, Sendable {
    var format = 1
    public var options = SearchOptions()
    public var directory = ""
    public var filters = "*.*"
    public var queryHistory: [String] = []
    public var replacementHistory: [String] = []
    public var directoryHistory: [String] = []
    public var filterHistory: [String] = []
    public var page: FindReplacePage = .find
    public var stayAfterReplace = false
    public var confirmsOpenReplacement = true

    /// 业务作用：建立独立于文档和窗口对象的搜索配置快照，供启动恢复与后台保存使用。
    /// 参数说明: 无。
    /// 返回：普通搜索、空历史和明确文件过滤的默认状态。
    public init() {}

    /// 业务作用：在归档解析后和编码前限定配置格式、历史条目和完整文本容量，拒绝无界配置分配。
    /// 参数说明: 无。
    /// 返回：已知格式、每类至多 30 项且原文合计不超过 16 MiB 时通过，超限不截断任何输入。
    public func validate() throws {
        // 未识别的配置格式可能包含不同语义，不能按当前控件解释后再覆盖原归档。
        guard format == 1 else {
            throw NateError.message("搜索设置格式无法识别，原归档已保留。")
        }
        let histories = [queryHistory, replacementHistory, directoryHistory, filterHistory]
        guard histories.allSatisfy({ $0.count <= 30 }) else {
            throw NateError.message("搜索历史每类最多 30 项，原归档已保留。")
        }
        var remaining = 16 * 1024 * 1024
        for value in [options.query, options.replacement, directory, filters] + histories.flatMap({ $0 }) {
            let count = value.utf8.count
            guard count <= remaining else {
                throw NateError.message("搜索设置完整文本合计超过 16 MiB，未保存；可清理历史后重试。")
            }
            remaining -= count
        }
    }
}
