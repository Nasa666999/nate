import Foundation
import NateSearch

extension ApplicationController {
    /// 业务作用：明确目录输入通过验证后进入统一文件搜索，完整原条件持续约束后台计划。
    /// 参数说明:
    /// - directory: 用户填写的搜索根。
    /// - filters: 包含、排除和目录排除模式。
    /// - options: 搜索与替换条件。
    /// - replacing: 是否在确认后修改文件。
    /// 返回：合法目录启动真实搜索，空输入或 NUL 不触发文件访问。
    func searchDirectory(_ directory: String, filters: String, options: SearchOptions, replacing: Bool) {
        guard !directory.isEmpty else {
            findWindow?.feedback.stringValue = "请先填写明确的搜索目录。"
            return
        }
        // 路径在构造 URL 之前就拒绝 NUL，不能把无效目录默默转换为包含 %00 的另一目录。
        guard !directory.utf8.contains(0) else {
            findWindow?.feedback.stringValue = "搜索目录不能包含 NUL。"
            return
        }
        let input = SearchRequestInput(findWindow)
        searchFiles(
            source: .directory(URL(fileURLWithPath: directory, isDirectory: true)),
            filters: filters,
            options: options,
            replacing: replacing,
            current: {
                [weak self] in
                guard let self, input.matches(self.findWindow) else {
                    return false
                }
                return self.findWindow?.matchesDirectoryRequest(
                    options: options,
                    directory: directory,
                    filters: filters
                ) == true
            }
        )
    }
}
