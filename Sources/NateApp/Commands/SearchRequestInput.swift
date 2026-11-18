import Foundation
import NateUI

@MainActor
final class SearchRequestInput {
    private weak var window: FindReplaceWindow?
    private let contents: [UUID]?
    private let configuration: UUID?

    /// 业务作用：执行请求固定原查找窗口、完整原文和通用选项，不以最终外观相同重新授予旧计划权限。
    /// 参数说明:
    /// - window: 当前拥有该请求的查找窗口，后台无窗口上下文时为空。
    /// 返回：不保留原文或窗口的轻量运行期证据，正常结束编辑不改变内容资格。
    init(_ window: FindReplaceWindow?) {
        self.window = window
        contents = window?.contentIdentities
        configuration = window?.configurationIdentity
    }

    /// 业务作用：发布结果或开始写入前确认请求仍属同一完整输入，往返修改和换窗口不能复用旧证据。
    /// 参数说明:
    /// - candidate: 当前实际查找窗口。
    /// 返回：窗口、原文及通用配置均未变化时为真，不比较或保存完整表达式字符串。
    func matches(_ candidate: FindReplaceWindow?) -> Bool {
        candidate === window && candidate?.contentIdentities == contents
            && candidate?.configurationIdentity == configuration
    }
}
