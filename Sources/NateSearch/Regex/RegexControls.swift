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
            if throughAlternative, let instruction = removed.pending.last {
                switch instruction {
                case .alternative, .resetAlternative:
                    return
                default:
                    break
                }
            }
        }
    }

    /// 业务作用：分支重置组提前接受后仍按原声明顺序处理后续复用编号，已闭合捕获不能保留另一分支的旧起点。
    /// 参数说明:
    /// - node: 提前接受后不再消费正文的后续分支。
    /// - state: 当前成功路径的捕获与真实接受位置。
    /// - depth: 当前有界语法遍历深度。
    /// 返回：已参与的复用捕获沿接受位置重置；捕获将形成反向范围或共同预算不足时整次搜索失败。
    mutating func resetAcceptedCaptures(_ node: RegexNode, state: inout MatchState, depth: Int = 0) throws {
        try checkpoint()
        guard depth < 256 else {
            throw NateError.message("正则接受时的捕获遍历超过 256 层。")
        }
        switch node {
        case .capture(let id, let child):
            if let previous = state.captures[id] {
                let end = previous.location + previous.length
                // 后续分支不能把已结束的捕获改成反向范围；拒绝不发布命中，也不准备可能丢失正文的替换。
                guard end >= state.position else {
                    throw NateError.message("分支重置后的提前接受产生反向捕获范围，未发布搜索结果。")
                }
                state.captures[id] = NSRange(location: state.position, length: end - state.position)
            }
            try resetAcceptedCaptures(child, state: &state, depth: depth + 1)
        case .sequence(let children), .alternate(let children), .resetAlternate(let children):
            for child in children {
                try resetAcceptedCaptures(child, state: &state, depth: depth + 1)
            }
        case .repeatNode(let child, _, _, _, _), .assertion(let child, _, _), .atomic(let child),
            .flags(_, _, _, let child):
            try resetAcceptedCaptures(child, state: &state, depth: depth + 1)
        case .conditional(let condition, let yes, let no):
            if case .assertion(let child) = condition {
                try resetAcceptedCaptures(child, state: &state, depth: depth + 1)
            }
            try resetAcceptedCaptures(yes, state: &state, depth: depth + 1)
            try resetAcceptedCaptures(no, state: &state, depth: depth + 1)
        default:
            break
        }
    }
}
