import Foundation
import NateCore

enum RegexVerb: String, Sendable {
    case fail = "FAIL"
    case accept = "ACCEPT"
    case prune = "PRUNE"
    case skip = "SKIP"
    case commit = "COMMIT"
    case then = "THEN"
}

enum RegexRestart {
    case next
    case position(Int)
    case stop
}

extension CancellableMatcher {
    /// 业务作用：原子区域提前接受后优先继续外层正文，外层失败时仍保留已经确认的接受位置。
    /// 参数说明:
    /// - accepted: 原子区域返回的首个成功状态。
    /// - path: 外层仍需完成的续接与捕获。
    /// - choices: 按优先级保留的回退候选。
    /// 返回：外层从接受位置继续，必要的提前接受候选仍受共享容量约束。
    mutating func acceptAtomic(_ accepted: MatchState, path: inout RegexPath, choices: inout [RegexPath])
        throws
    {
        if accepted.accepted {
            var fallback = path
            fallback.state = accepted
            try fork([], from: fallback, into: &choices)
        }
        path.state = accepted
        path.state.accepted = false
    }

    /// 业务作用：控制点取消旧回退资格，同时释放被撤销路径真实保留的续接配额。
    /// 参数说明:
    /// - choices: 当前区域还未尝试的有序路径。
    /// - throughAlternative: 为真时只撤销至最近的分支候选并包含该候选，否则撤销全部旧路径。
    /// 返回：仅控制点之后新增的候选可以继续；外层区域是否受影响由调用边界决定。
    mutating func trim(_ choices: inout [RegexPath], throughAlternative: Bool) {
        while let removed = choices.popLast() {
            release(removed)
            if throughAlternative, let instruction = removed.pending.last,
                case .alternative = instruction
            {
                break
            }
        }
    }
}
