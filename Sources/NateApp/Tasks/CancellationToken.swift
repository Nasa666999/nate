import Foundation
import NateCore
import os

enum PublicationStatus: Sendable, Equatable {
    case unused
    case revoked
    case started
    case completed
    case failed
}

private struct CancellationState {
    var cancelled = false
    var publication: PublicationStatus = .unused
    var children: [CancellationToken] = []
}

final class CancellationToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CancellationState())
    var isCancelled: Bool {
        state.withLock {
            $0.cancelled
        }
    }
    var publicationStatus: PublicationStatus {
        state.withLock {
            $0.publication
        }
    }
    var hasActivePublication: Bool {
        state.withLock {
            value in
            value.publication == .started
                || value.children.contains {
                    $0.hasActivePublication
                }
        }
    }

    /// 业务作用：取消请求跨专用 I/O 线程传播，不依赖该线程的 Swift 任务上下文。
    /// 参数说明: 无。
    /// 返回：后续预算检查与发布门禁能观察到取消。
    func cancel() {
        state.withLock {
            $0.cancelled = true
            // 尚未进入发布的令牌立即失效，后续系统动作不能再取得这份权限。
            if $0.publication == .unused {
                $0.publication = .revoked
            }
            // 派生关系只沿树向下传播；返回取消前，每个当前子动作都已确定撤销或进入发布。
            for child in $0.children {
                child.cancel()
            }
        }
    }

    /// 业务作用：耗时遍历和发布之前主动结束已撤销请求。
    /// 参数说明: 无。
    /// 返回：取消时抛错，不把部分结果描述为全部完成。
    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    /// 业务作用：取消和进入单次外部发布步骤在同一锁内决定顺序，系统动作不在锁内阻塞取消调用者。
    /// 参数说明:
    /// - operation: 取得本次权威后同步执行的文件动作。
    /// 返回：动作实际完成或失败；已撤销及已使用的权限不能再次进入发布。
    func withPublication(_ operation: () throws -> Void) throws {
        let admitted = state.withLock {
            value in
            guard !value.cancelled, value.publication == .unused else {
                return false
            }
            // 先记录已取得权威，再离开锁执行系统调用，取消方据此保留未决动作。
            value.publication = .started
            return true
        }
        guard admitted else {
            throw CancellationError()
        }
        // 动作一旦取得权威就可能进入不可中断的系统调用，取消不能再冒称它从未开始。
        do {
            try operation()
            state.withLock {
                $0.publication = .completed
            }
        }
        catch {
            state.withLock {
                $0.publication = .failed
            }
            throw error
        }
    }

    /// 业务作用：批量文件动作共享取消源，但每份文件分别取得一次发布权。
    /// 参数说明:
    /// - operation: 使用独立派生令牌同步完成的单项动作。
    /// 返回：实际单项结果；父请求取消后不能创建新的有效发布动作。
    func withChild<Value>(_ operation: (CancellationToken) throws -> Value) throws -> Value {
        let child = CancellationToken()
        // 派生资格与父取消串行判断，批量动作不能在取消后补发新的文件操作。
        state.withLock {
            value in
            if value.cancelled {
                child.cancel()
            }
            else {
                value.children.append(child)
            }
        }
        defer {
            state.withLock {
                value in
                value.children.removeAll {
                    $0 === child
                }
            }
        }
        try child.check()
        return try operation(child)
    }
}
