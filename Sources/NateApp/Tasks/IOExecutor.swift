import Foundation
import os

struct IOExecutorUnavailable: Error, LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? {
        reason
    }
}

struct IOExecutorSnapshot: Sendable {
    let running: Int
    let stalled: Int
    let queued: Int
    let quarantined: Bool
    let workerLimit: Int
}

private enum IOLeasePhase: Equatable {
    case queued
    case running
    case stalled
}

private final class IOSynchronousAction: Sendable {
    private let body: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    /// 业务作用：排队闭包可在拒绝时释放完整快照，而不等待被取消的队列对象调度。
    /// 参数说明:
    /// - body: 尚未开始的同步动作。
    /// 返回：一次性动作容器。
    init(_ body: @escaping @Sendable () -> Void) {
        self.body = OSAllocatedUnfairLock(initialState: body)
    }

    /// 业务作用：运行和拒绝共用一次提取资格，快照不会被队列历史无期限保留。
    /// 参数说明: 无。
    /// 返回：首次取得原动作，随后为空；丢弃返回值即释放未开始闭包。
    func take() -> (@Sendable () -> Void)? {
        body.withLock {
            let taken = $0
            $0 = nil
            return taken
        }
    }
}

private struct IOLease {
    var phase = IOLeasePhase.queued
    let operation: BlockOperation
    let action: IOSynchronousAction
    let reject: @Sendable (any Error) -> Void
}

private struct IOExecutorState {
    var leases: [UUID: IOLease] = [:]
    var stalled = 0
}

private final class IOCompletion<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, any Error>?>

    /// 业务作用：排队拒绝与真实系统返回共享唯一恢复资格，不能重复恢复等待者。
    /// 参数说明:
    /// - continuation: 等待完整 I/O 结果的调用者。
    /// 返回：一次性完成入口。
    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    /// 业务作用：只允许第一个实际结果或未开始拒绝恢复调用者。
    /// 参数说明:
    /// - result: 系统返回值或未开始错误。
    /// 返回：首次回传生效，迟到结果不再次恢复。
    func finish(_ result: Result<Value, any Error>) {
        let taken = continuation.withLock {
            let taken = $0
            $0 = nil
            return taken
        }
        taken?.resume(with: result)
    }
}

final class IOExecutor: Sendable {
    private let queue: OperationQueue
    private let state = OSAllocatedUnfairLock(initialState: IOExecutorState())
    private let configuration = OSAllocatedUnfairLock(initialState: ())
    private let baseConcurrency: Int
    private let maximumStalled: Int
    private let stallAfter: Duration
    let readCancellations = OSAllocatedUnfairLock(initialState: [UUID: @Sendable () -> Void]())

    var snapshot: IOExecutorSnapshot {
        state.withLock {
            value in
            IOExecutorSnapshot(
                running: value.leases.values.filter {
                    $0.phase == .running
                }.count,
                stalled: value.stalled,
                queued: value.leases.values.filter {
                    $0.phase == .queued
                }.count,
                quarantined: isQuarantined(value),
                workerLimit: baseConcurrency + min(maximumStalled, value.stalled)
            )
        }
    }

    /// 业务作用：同步 I/O 使用独立线程，慢系统调用只取得有上限的替补，不能无限扩张线程和快照。
    /// 参数说明:
    /// - name: 队列用途。
    /// - concurrency: 正常并发上限。
    /// - maximumStalled: 超时操作替补上限，最多 8；为零时保留严格串行用途。
    /// - stallAfter: 单个已开始操作被记录为未返回的时间。
    /// 返回：最多保留 128 个排队请求，达到未返回上限后拒绝尚未开始的动作。
    init(name: String, concurrency: Int, maximumStalled: Int = 8, stallAfter: Duration = .seconds(30)) {
        baseConcurrency = max(1, concurrency)
        self.maximumStalled = min(8, max(0, maximumStalled))
        self.stallAfter = max(.milliseconds(1), stallAfter)
        let queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = baseConcurrency
        queue.qualityOfService = .utility
        self.queue = queue
    }

    /// 业务作用：异步等待完整 I/O 结果，运行中的写入不会因超时而冒充结束或释放其发布位置。
    /// 参数说明:
    /// - body: 只捕获 Sendable 固定快照的同步操作。
    /// 返回：真实返回值或实际失败；被隔离队列拒绝的操作从未进入闭包。
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation {
            continuation in
            let completion = IOCompletion<T>(continuation)
            enqueue(
                id: UUID(),
                operation: {
                    completion.finish(
                        Result {
                            try body()
                        }
                    )
                },
                reject: {
                    completion.finish(.failure($0))
                }
            )
        }
    }

    /// 业务作用：统一登记只读与写入线程，队列拒绝必须在同步动作开始之前发生。
    /// 参数说明:
    /// - id: 本次线程占用的稳定身份。
    /// - operation: 完整同步动作，返回后才释放线程占用。
    /// - reject: 尚未开始时回传的明确失败。
    /// 返回：动作进入独立队列，或被未返回上限及排队预算拒绝。
    func enqueue(
        id: UUID,
        operation: @escaping @Sendable () -> Void,
        reject: @escaping @Sendable (any Error) -> Void
    ) {
        let action = IOSynchronousAction(operation)
        let block = BlockOperation {
            [self] in
            guard start(id) else {
                return
            }
            let timer = Task.detached(priority: .utility) {
                [self] in
                do {
                    try await Task.sleep(for: stallAfter)
                }
                catch {
                    return
                }
                markStalled(id)
            }
            defer {
                timer.cancel()
                finish(id)
            }
            action.take()?()
        }
        let error = state.withLock {
            value -> IOExecutorUnavailable? in
            guard !isQuarantined(value) else {
                return IOExecutorUnavailable(
                    reason: "已有 \(value.stalled) 个系统 I/O 超时仍未返回，通道已暂停新动作；在途请求继续保留，请等待系统恢复后重试。"
                )
            }
            guard
                value.leases.values.filter({
                    $0.phase == .queued
                }).count < 128
            else {
                return IOExecutorUnavailable(reason: "文件操作排队已达到 128 项上限，本次动作尚未开始。")
            }
            value.leases[id] = IOLease(operation: block, action: action, reject: reject)
            return nil
        }
        if let error {
            _ = action.take()
            reject(error)
        }
        else {
            queue.addOperation(block)
        }
    }

    /// 业务作用：工作线程先取得登记中的执行资格，被撤销的排队动作不能晚到执行。
    /// 参数说明:
    /// - id: 队列回调的请求身份。
    /// 返回：仍在排队的请求原子转为运行时为真，否则不进入业务闭包。
    private func start(_ id: UUID) -> Bool {
        state.withLock {
            value in
            // 等待期间可能已经被取消或隔离，缺失的登记不能成为迟到执行的资格。
            guard value.leases[id]?.phase == .queued else {
                return false
            }
            value.leases[id]?.phase = .running
            return true
        }
    }

    /// 业务作用：记录未返回的系统调用并提供有限替补，超出预算先隔离未开始请求。
    /// 参数说明:
    /// - id: 已超过等待预算的请求身份。
    /// 返回：在途动作继续登记，隔离不会把它当成完成或释放文件发布权限。
    private func markStalled(_ id: UUID) {
        let rejected = state.withLock {
            value -> [IOLease] in
            guard value.leases[id]?.phase == .running else {
                return []
            }
            value.leases[id]?.phase = .stalled
            value.stalled += 1
            guard isQuarantined(value) else {
                return []
            }
            // 已运行请求仍可能持有系统副作用，只有尚未开始的请求可以直接拒绝并释放快照。
            let queued = value.leases.filter {
                $0.value.phase == .queued
            }
            for key in queued.keys {
                value.leases.removeValue(forKey: key)
            }
            return Array(queued.values)
        }
        adjustWorkerLimit()
        for lease in rejected {
            lease.operation.cancel()
            _ = lease.action.take()
            lease.reject(IOExecutorUnavailable(reason: "系统 I/O 未返回数量达到上限，本次排队动作尚未开始，稍后可重试。"))
        }
    }

    /// 业务作用：只读调用者停止等待时撤去排队资格，已经开始的系统调用继续占用有限记录。
    /// 参数说明:
    /// - id: 只读请求身份。
    /// - reason: 超时或用户取消原因。
    /// 返回：未开始动作被拒绝；运行中的只读动作记为未返回并取得有限替补。
    func abandonRead(_ id: UUID, reason: any Error) {
        let queued = state.withLock {
            value -> IOLease? in
            guard value.leases[id]?.phase == .queued else {
                return nil
            }
            return value.leases.removeValue(forKey: id)
        }
        if let queued {
            queued.operation.cancel()
            _ = queued.action.take()
            queued.reject(reason)
        }
        else {
            markStalled(id)
        }
    }

    /// 业务作用：实际系统调用返回后才收回占用，隔离条件解除时允许新的独立动作。
    /// 参数说明:
    /// - id: 真正结束的请求身份。
    /// 返回：撤销替补配额，旧排队拒绝不会自动重新执行。
    private func finish(_ id: UUID) {
        state.withLock {
            value in
            if value.leases.removeValue(forKey: id)?.phase == .stalled {
                value.stalled -= 1
            }
        }
        adjustWorkerLimit()
    }

    /// 业务作用：队列隔离取决于真实未返回数量，严格串行通道不因替补发生并发发布。
    /// 参数说明:
    /// - value: 当前线程占用状态。
    /// 返回：未返回数量达到预算时为真。
    private func isQuarantined(_ value: IOExecutorState) -> Bool {
        value.stalled >= max(1, maximumStalled)
    }

    /// 业务作用：串行更新并发配额，迟到的计时或完成回调不能覆盖更新后的线程预算。
    /// 参数说明: 无。
    /// 返回：实际并发不超过正常上限加 8，系统调用恢复后缩回正常上限。
    private func adjustWorkerLimit() {
        configuration.withLock {
            let limit = state.withLock {
                baseConcurrency + min(maximumStalled, $0.stalled)
            }
            queue.maxConcurrentOperationCount = limit
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
