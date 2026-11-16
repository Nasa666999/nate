import Foundation
import NateCore

private enum RepeatFrame {
    case visit(MatchState, Int, Bool)
    case accept(MatchState)
}

extension CancellableMatcher {
    /// 业务作用：按分支优先级深度优先展开重复，使贪婪、懒惰与占有匹配保留捕获顺序。
    /// 参数说明:
    /// - child: 单次重复的表达式。
    /// - state: 重复开始前的输入位置与捕获。
    /// - minimum: 必须成功的次数。
    /// - maximum: 允许的最多次数。
    /// - greedy: 是否先尝试更多次数。
    /// - possessive: 是否禁止向外层提供重复的回退路径。
    /// - depth: 外层执行树深度。
    /// 返回：有优先级的结果；空匹配停止扩展，预算耗尽则整次失败。
    mutating func repeatStates(
        _ child: RegexNode,
        _ state: MatchState,
        minimum: Int,
        maximum: Int,
        greedy: Bool,
        possessive: Bool,
        depth: Int
    ) throws -> [MatchState] {
        var frames: [RepeatFrame] = [.visit(state, 0, true)]
        var results: [MatchState] = []
        while let frame = frames.popLast() {
            try checkpoint()
            switch frame {
            case .accept(let accepted):
                results.append(accepted)
                if possessive {
                    return results
                }
            case .visit(let current, let count, let canExpand):
                if !greedy, count >= minimum {
                    results.append(current)
                    if possessive {
                        return results
                    }
                }
                if greedy, count >= minimum {
                    frames.append(.accept(current))
                }
                if canExpand, count < maximum {
                    let successors = try run(child, current, depth: depth + 1)
                    for successor in successors.reversed() {
                        // 零长度成功仍可参与捕获，但达到必需次数后不再沿同一位置无限展开。
                        let expand = successor.position != current.position || count + 1 < minimum
                        frames.append(.visit(successor, count + 1, expand))
                    }
                }
            }
            guard frames.count + results.count <= 100_000 else {
                throw NateError.message("重复匹配超过内存预算。")
            }
        }
        return results
    }
}
