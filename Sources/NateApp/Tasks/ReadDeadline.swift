import Foundation
import os

struct ReadDeadlineExceeded: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "文件系统或系统授权仍未完成响应，已停止等待本次读取。原文件没有被读取任务修改，可通过文件面板重新选择或稍后重试。"
    }
}

private struct ReadWaitState<Value: Sendable> {
    var continuation: CheckedContinuation<Value, any Error>?
    var result: Result<Value, any Error>?
    var finished = false
    var installed = false
    var timer: Task<Void, Never>?
}

private final class ReadWait<Value: Sendable>: Sendable {
    let state = OSAllocatedUnfairLock(initialState: ReadWaitState<Value>())
    var finished: Bool {
        state.withLock {
            $0.finished
        }
    }

    /// 业务作用：注册等待者前后的取消使用同一状态，不能丢失抢先到达的取消。
    /// 参数说明:
    /// - continuation: 唯一读取等待者。
    /// 返回：已完成请求立即恢复，否则登记等待。
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let early = state.withLock {
            value -> Result<Value, any Error>? in
            value.installed = true
            if value.finished {
                let result = value.result
                value.result = nil
                return result
            }
            value.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    /// 业务作用：超时、取消和系统返回只能有一个结果恢复调用者，迟到读取不再发布标签。
    /// 参数说明:
    /// - result: 本次竞争提交的结果。
    /// 返回：首次结果生效并释放等待者；其余结果丢弃。
    func finish(_ result: Result<Value, any Error>) {
        let taken = state.withLock {
            value -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?) in
            guard !value.finished else {
                return (nil, nil)
            }
            value.finished = true
            let continuation = value.continuation
            let timer = value.timer
            value.continuation = nil
            value.timer = nil
            if !value.installed {
                value.result = result
            }
            return (continuation, timer)
        }
        taken.1?.cancel()
        taken.0?.resume(with: result)
    }

    /// 业务作用：读取已经结束时不留下无主计时任务，正常等待时登记唯一截止时间。
    /// 参数说明:
    /// - timer: 本次读取的截止任务。
    /// 返回：完成请求立即取消计时器。
    func setTimer(_ timer: Task<Void, Never>) {
        let cancel = state.withLock {
            value in
            if value.finished {
                return true
            }
            value.timer = timer
            return false
        }
        if cancel {
            timer.cancel()
        }
    }
}

extension IOExecutor {
    /// 业务作用：只读遍历同时接收取消令牌和等待上限，系统调用晚到也不能再发布计划。
    /// 参数说明:
    /// - body: 只读操作，定期检查显式取消令牌。
    /// 返回：完整计划、取消或超时；不允许在此闭包内写入文件。
    func readCancellable<Value: Sendable>(_ body: @escaping @Sendable (CancellationToken) throws -> Value)
        async throws -> Value
    {
        let token = CancellationToken()
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await read {
                        try token.check()
                        return try body(token)
                    }
                }
                catch {
                    token.cancel()
                    throw error
                }
            },
            onCancel: {
                token.cancel()
            }
        )
    }

    /// 业务作用：只读访问可停止等待系统调用，取消后迟到结果没有正文或原文件副作用。
    /// 参数说明:
    /// - timeout: 等待上限；不表示操作系统调用已被强行终止。
    /// - body: 仅执行读取和不可变解析，不得包含磁盘发布。
    /// 返回：读取结果、取消或明确超时，后台线程仍受队列并发上限约束。
    func read<Value: Sendable>(
        timeout: Duration = .seconds(30),
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let wait = ReadWait<Value>()
        let id = UUID()
        readCancellations.withLock {
            $0[id] = {
                wait.finish(.failure(CancellationError()))
            }
        }
        defer {
            _ = readCancellations.withLock {
                $0.removeValue(forKey: id)
            }
        }
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    continuation in
                    wait.install(continuation)
                    guard !wait.finished else {
                        return
                    }
                    let timer = Task.detached(priority: .utility) {
                        do {
                            try await Task.sleep(for: timeout)
                        }
                        catch {
                            return
                        }
                        wait.finish(.failure(ReadDeadlineExceeded()))
                    }
                    wait.setTimer(timer)
                    queue.addOperation {
                        guard !wait.finished else {
                            return
                        }
                        wait.finish(
                            Result {
                                try body()
                            }
                        )
                    }
                }
            },
            onCancel: {
                wait.finish(.failure(CancellationError()))
            }
        )
    }

    /// 业务作用：用户取消读取只撤去等待与发布资格，不声称终止了内核中阻塞的系统调用。
    /// 参数说明: 无。
    /// 返回：全部当前只读等待者收到取消；保存通道不受影响。
    func cancelReads() {
        let cancellations = readCancellations.withLock {
            Array($0.values)
        }
        for cancel in cancellations {
            cancel()
        }
    }
}
