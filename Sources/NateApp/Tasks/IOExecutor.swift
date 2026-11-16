import Foundation

final class IOExecutor: Sendable {
    let queue: OperationQueue

    /// 业务作用：阻塞磁盘访问使用有界专用线程，不占满 Swift 协作执行线程。
    /// 参数说明:
    /// - name: 队列用途。
    /// - concurrency: 同时阻塞操作数上限。
    /// 返回：独立的后台 I/O 执行边界。
    init(name: String, concurrency: Int) {
        let queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .utility
        self.queue = queue
    }

    /// 业务作用：异步等待完整 I/O 结果，主线程可继续处理输入和取消。
    /// 参数说明:
    /// - body: 只捕获 Sendable 固定快照的同步操作。
    /// 返回：原操作结果或实际失败。
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation {
            continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try body())
                }
                catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 业务作用：将任务取消传给同步 I/O 边界，操作自行在安全阶段检查。
    /// 参数说明:
    /// - body: 接收明确取消令牌的后台操作。
    /// 返回：实际结果或取消，不通过 Task.cancel 假装底层已停止。
    func runCancellable<T: Sendable>(_ body: @escaping @Sendable (CancellationToken) throws -> T) async throws
        -> T
    {
        let token = CancellationToken()
        return try await withTaskCancellationHandler(
            operation: {
                try await run {
                    try token.check()
                    return try body(token)
                }
            },
            onCancel: {
                token.cancel()
            }
        )
    }
}
