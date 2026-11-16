import Foundation
import NateCore
import os

final class CancellationToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool {
        state.withLock {
            $0
        }
    }

    /// 业务作用：取消请求跨专用 I/O 线程传播，不依赖该线程的 Swift 任务上下文。
    /// 参数说明: 无。
    /// 返回：后续预算检查与发布门禁能观察到取消。
    func cancel() {
        state.withLock {
            $0 = true
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
}
