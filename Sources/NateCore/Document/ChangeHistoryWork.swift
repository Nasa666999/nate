import Foundation

struct ChangeHistoryWork: Sendable {
    let deadline: ContinuousClock.Instant?
    let permit: (@Sendable () -> Bool)?

    /// 业务作用：同步和后台历史准备显式携带同一截止及来源资格，不依赖调用方已经建立并发任务。
    /// 参数说明:
    /// - deadline: 本次完整候选的可选计算截止。
    /// - permit: 本次完整候选的可选来源资格。
    /// 返回：仅用于当前调用的不可变执行证据。
    init(deadline: ContinuousClock.Instant? = nil, permit: (@Sendable () -> Bool)? = nil) {
        self.deadline = deadline
        self.permit = permit
    }

    /// 业务作用：完整历史候选共享调用方的截止和来源资格，内部区间操作不延长执行窗口。
    /// 参数说明: 无。
    /// 返回：未取消且来源与截止仍有效时通过，否则立即停止当前候选。
    func check() throws {
        try Task.checkCancellation()
        guard permit?() != false,
            deadline.map({
                ContinuousClock.now < $0
            }) != false
        else {
            throw NateError.message("修改历史来源失效或超过共同计算截止，未采用部分记录。")
        }
    }
}
