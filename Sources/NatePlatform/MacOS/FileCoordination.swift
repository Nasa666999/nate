import Foundation
import os

public struct FileCoordinationFailure: Error, LocalizedError, Sendable {
    let message: String
    public var errorDescription: String? {
        message
    }
}

private enum CoordinationPhase {
    case waiting
    case accessing
    case finished
}

private enum CoordinationStop {
    case cancelled
    case expired
}

private struct CoordinationState {
    var phase: CoordinationPhase = .waiting
    var stop: CoordinationStop?
}

// 每个对象只协调一个同步动作；其他线程仅调用系统明确允许跨线程使用的 cancel。
private final class CoordinationWait: @unchecked Sendable {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let state = OSAllocatedUnfairLock(initialState: CoordinationState())
    let deadline: ContinuousClock.Instant

    /// 业务作用：为单次系统协调建立有限等待期，已进入访问动作后的持久化由实际阶段确认。
    /// 参数说明:
    /// - timeout: 取得访问权的等待预算，必须大于零且不超过一小时。
    /// 返回：独立协调上下文；非法预算在系统访问前失败。
    init(timeout: Duration) throws {
        guard timeout > .zero, timeout <= .seconds(3600) else {
            throw FileCoordinationFailure(message: "文件协调等待预算无效。")
        }
        deadline = ContinuousClock.now.advanced(by: timeout)
    }

    /// 业务作用：等待访问权时同时检查取消和截止，不把失效等待转成迟到的文件动作。
    /// 参数说明:
    /// - permit: 本次请求仍有效的权限。
    /// 返回：需要停止等待时调用线程安全的系统取消入口。
    func inspect(permit: @Sendable () -> Bool) {
        let permitted = permit()
        let cancel = state.withLock {
            value in
            guard value.phase != .finished, value.stop == nil else {
                return false
            }
            if !permitted {
                value.stop = .cancelled
                return true
            }
            if value.phase == .waiting, ContinuousClock.now >= deadline {
                value.stop = .expired
                return true
            }
            return false
        }
        if cancel {
            // 系统等待尚未授权文件动作，撤销它可阻止失效请求取得新的协调回调。
            coordinator.cancel()
        }
    }

    /// 业务作用：取得协调回调后再复验请求，避免取消与授予访问权之间的竞争产生副作用。
    /// 参数说明:
    /// - permit: 仍有效的请求权限。
    /// 返回：允许同步执行访问时为真；拒绝时保留实际停止原因。
    func begin(permit: @Sendable () -> Bool) -> Bool {
        let permitted = permit()
        return state.withLock {
            value in
            if !permitted, value.stop == nil {
                value.stop = .cancelled
            }
            if value.phase == .waiting, value.stop == nil, ContinuousClock.now >= deadline {
                value.stop = .expired
            }
            // 授权回调可能与取消或截止同时到达，停止原因已发布时不能进入访问阶段。
            guard value.stop == nil else {
                return false
            }
            value.phase = .accessing
            return true
        }
    }

    /// 业务作用：同步动作结束后解除计时观察，协调对象不再接受新的访问动作。
    /// 参数说明: 无。
    /// 返回：后续计时回调不再取消已结束的动作。
    func finish() {
        state.withLock {
            $0.phase = .finished
        }
    }

    /// 业务作用：实际文件动作结果优先于迟到取消，已经发布的写入不能被伪报为未执行。
    /// 参数说明:
    /// - result: 协调回调内完成的实际访问结果。
    /// - error: 平台等待失败原因。
    /// 返回：真实动作结果；没有进入动作时返回取消、等待截止或平台失败。
    func resolve<Value>(_ result: Result<Value, any Error>?, error: NSError?) throws -> Value {
        if let result {
            return try result.get()
        }
        switch state.withLock({
            $0.stop
        }) {
        case .cancelled: throw CancellationError()
        case .expired:
            throw FileCoordinationFailure(message: "系统文件协调等待超过上限，本次请求未取得文件访问权。")
        case nil:
            if let error {
                throw error
            }
            throw FileCoordinationFailure(message: "系统文件协调没有授予访问权。")
        }
    }

    /// 业务作用：独立计时队列可以撤销系统协调等待，不依赖被阻塞的文件执行线程。
    /// 参数说明:
    /// - permit: 请求取消权限。
    /// 返回：调用方在同步协调结束时必须取消的计时器。
    func timer(permit: @escaping @Sendable () -> Bool) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            [self] in inspect(permit: permit)
        }
        timer.resume()
        return timer
    }
}

public enum PlatformFileCoordinator {
    /// 业务作用：读取在同步系统协调范围内完成，回调返回后不再持有文件访问权。
    /// 参数说明:
    /// - url: 原请求路径。
    /// - timeout: 取得访问权的等待上限，默认 30 秒。
    /// - permit: 等待和进入读取时有效的请求权限。
    /// - operation: 使用系统返回 URL 同步执行的只读动作。
    /// 返回：实际读取结果；取消、协调截止或读取失败明确抛错。
    public static func read<Value: Sendable>(
        at url: URL,
        timeout: Duration = .seconds(30),
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        let wait = try CoordinationWait(timeout: timeout)
        let timer = wait.timer(permit: permit)
        defer {
            wait.finish()
            timer.cancel()
        }
        var error: NSError?
        var result: Result<Value, any Error>?
        wait.coordinator.coordinate(readingItemAt: url, options: [], error: &error) {
            current in
            guard wait.begin(permit: permit) else {
                return
            }
            result = Result {
                try operation(current)
            }
        }
        return try wait.resolve(result, error: error)
    }

    /// 业务作用：为同一文档更新与另存替换使用明确的系统写入意图，不把原子换文件误作新文档替换。
    /// 参数说明:
    /// - url: 原请求路径。
    /// - options: 与业务动作一致的系统写入意图。
    /// - timeout: 取得访问权的等待上限。
    /// - permit: 等待和发布前的请求权限。
    /// - operation: 协调范围内同步完成的动作。
    /// 返回：真实动作结果；已进入动作后的取消不掩盖实际写入结果。
    public static func write<Value: Sendable>(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        timeout: Duration = .seconds(30),
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        let wait = try CoordinationWait(timeout: timeout)
        let timer = wait.timer(permit: permit)
        defer {
            wait.finish()
            timer.cancel()
        }
        var error: NSError?
        var result: Result<Value, any Error>?
        wait.coordinator.coordinate(writingItemAt: url, options: options, error: &error) {
            current in
            guard wait.begin(permit: permit) else {
                return
            }
            result = Result {
                try operation(current)
            }
        }
        return try wait.resolve(result, error: error)
    }

    /// 业务作用：移动同时协调原路径与目标路径，避免协作读取跨越半完成的重命名。
    /// 参数说明:
    /// - source: 原请求源路径。
    /// - destination: 用户确认的新路径。
    /// - timeout: 协调等待上限。
    /// - permit: 当前动作权限。
    /// - operation: 同步完成移动与结果确认的动作。
    /// 返回：完整结果；任一协调目标失效时不执行动作。
    public static func move<Value: Sendable>(
        from source: URL,
        to destination: URL,
        timeout: Duration = .seconds(30),
        permit: @escaping @Sendable () -> Bool,
        operation: (URL, URL) throws -> Value
    ) throws -> Value {
        let wait = try CoordinationWait(timeout: timeout)
        let timer = wait.timer(permit: permit)
        defer {
            wait.finish()
            timer.cancel()
        }
        var error: NSError?
        var result: Result<Value, any Error>?
        wait.coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &error
        ) {
            currentSource,
            currentDestination in
            guard wait.begin(permit: permit) else {
                return
            }
            result = Result {
                try operation(currentSource, currentDestination)
            }
        }
        return try wait.resolve(result, error: error)
    }
}
