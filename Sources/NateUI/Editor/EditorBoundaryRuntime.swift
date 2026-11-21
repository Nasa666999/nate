import Foundation
import NateCore

@MainActor
final class EditorBoundaryRuntime {
    var words = WordBoundarySettings()
    var wordGeneration = UUID()
    var delimiters = DelimiterSelectionSettings()
    var delimiterGeneration = UUID()
    var request = UUID()
    var task: Task<Void, Never>?

    /// 业务作用：每个克隆独立持有边界规则和临时选择任务，不共享异步选择权。
    /// 参数说明: 无。
    /// 返回：默认词规则、圆括号行内规则和空任务。
    init() {}

    /// 业务作用：新点击、文档切换或规则变化先撤销旧选择权，取消不能恢复先前请求身份。
    /// 参数说明: 无。
    /// 返回：旧后台工作收到取消，已有正文与选区保持不变。
    func cancelDelimiterSelection() {
        request = UUID()
        task?.cancel()
        task = nil
    }
}
