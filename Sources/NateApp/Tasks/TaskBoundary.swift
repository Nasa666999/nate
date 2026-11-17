import Foundation

@MainActor
enum TaskBoundary {
    /// 业务作用：让关闭和退出有明确等待边界，停止等待不代表同步 I/O 已结束。
    /// 参数说明:
    /// - deadline: 本次整个用户动作共用的单调截止时间。
    /// - pending: 主线程上读取的真实在途状态。
    /// 返回：实际状态在截止前结束时为真，超时或等待者取消时为假。
    static func wait(until deadline: ContinuousClock.Instant, while pending: () -> Bool) async -> Bool {
        while pending() {
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            }
            catch {
                return false
            }
        }
        return true
    }
}
