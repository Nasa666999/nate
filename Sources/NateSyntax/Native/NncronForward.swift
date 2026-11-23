import Foundation
import NateCore

extension NncronScanner {
    /// 业务作用：普通注释或任务的独立 CR/LF 归属沿原生延后呈现顺序确认，后继名称不能改变已确认的正文状态。
    /// 参数说明:
    /// - following: 同一固定原文中的完整下一物理行，最多 1 MiB。
    /// 返回：仅补全当前行未交付的结束字节；前瞻状态不发布，共享预算不足时拒绝当前整行。
    mutating func resolvedStyles(following: [UInt8]) throws -> [UInt8] {
        if emitted == bytes.count {
            return styles
        }
        guard emitted == bytes.count - 1, state.mode == 0,
            bytes.last == 10 || bytes.last == 13, following.count <= 1_048_576
        else {
            throw NateError.message("nnCron 缺少当前结束字节的完整后继证据。")
        }
        var forward = NncronScanner(
            bytes: following,
            rules: rules,
            budget: budget,
            state: state,
            styles: Array(repeating: 0, count: following.count)
        )
        let (classified, _) = try forward.scan()
        budget = forward.budget
        var output = styles
        output[emitted] = classified.first ?? 0
        try budget.check()
        return output
    }
}
