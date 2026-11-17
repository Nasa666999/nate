import Foundation
import NateCore

struct RegexRepeat {
    let child: RegexNode
    let minimum: Int
    let maximum: Int
    let greedy: Bool
    let depth: Int
    var count = 0
    var canExpand = true
}

enum RegexInstruction {
    case node(RegexNode, Int)
    case capture(Int, Int)
    case modes(Bool, Bool, Bool)
    case repetition(RegexRepeat)
    case repeated(RegexRepeat, Int)
    case alternative([RegexNode], Int, Int)
    case subroutine([Int: NSRange], Int?)
}

struct RegexPath {
    var state: MatchState
    var pending: [RegexInstruction]
}

extension CancellableMatcher {
    /// 业务作用：按实际回溯顺序寻找第一个完整成功路径，已经成功的分支不再计算无关后继。
    /// 参数说明:
    /// - node: 本次根表达式、原子区域或断言子树。
    /// - state: 当前起点、捕获和模式。
    /// - depth: 当前语法与子调用深度。
    /// - end: 完整命中可消费的最后边界；断言仍可读取范围外的真实正文。
    /// - requiredEnd: Lookbehind 必须结束的精确位置，为空时不增加此限制。
    /// 返回：首个满足终点限制的完整状态；全部路径失败时为空，取消或超限时整次搜索失败。
    mutating func firstMatch(
        _ node: RegexNode,
        _ state: MatchState,
        depth: Int = 0,
        end: Int? = nil,
        requiredEnd: Int? = nil
    ) throws -> MatchState? {
        var choices = [RegexPath(state: state, pending: [.node(node, depth)])]
        var pruned = false
        var thenEncountered = false
        try reserve(paths: 1, instructions: 1)
        defer {
            lastRegionPruned = pruned
            lastRegionThen = thenEncountered
            for choice in choices {
                release(choice)
            }
        }
        backtrack: while var path = choices.popLast() {
            defer {
                release(path)
            }
            while let instruction = path.pending.popLast() {
                retainedInstructions -= 1
                try checkpoint()
                if path.state.accepted {
                    switch instruction {
                    case .capture, .modes, .subroutine:
                        break
                    default:
                        continue
                    }
                }
                switch instruction {
                case .subroutine(let captures, let previousRecursion):
                    // 子程序内部捕获与递归身份只属于本次调用，返回后恢复调用方证据，定义块不能冒充已参与的捕获。
                    path.state.captures = captures
                    path.state.currentRecursion = previousRecursion
                    path.state.accepted = false
                case .capture(let id, let start):
                    path.state.captures[id] = NSRange(location: start, length: path.state.position - start)
                case .modes(let sensitive, let dot, let multiline):
                    path.state.sensitive = sensitive
                    path.state.dot = dot
                    path.state.multiline = multiline
                case .repetition(let repetition):
                    try scheduleRepeat(repetition, path: &path, choices: &choices)
                case .repeated(var repetition, let previous):
                    repetition.count += 1
                    // 空成功仍记录捕获，满足必需次数后停止同一位置扩展，避免零长度循环。
                    repetition.canExpand =
                        path.state.position != previous || repetition.count < repetition.minimum
                    try push(.repetition(repetition), onto: &path)
                case .alternative(let nodes, let index, let depth):
                    if index + 1 < nodes.count {
                        try fork([.alternative(nodes, index + 1, depth)], from: path, into: &choices)
                    }
                    try push(.node(nodes[index], depth), onto: &path)
                case .node(let node, let depth):
                    guard depth < 256 else {
                        throw NateError.message("正则递归超过 256 层。")
                    }
                    switch node {
                    case .directive, .empty:
                        break
                    case .literal, .any, .linebreak, .characterClass, .anchor, .reference:
                        guard let next = try consume(node, path.state) else {
                            continue backtrack
                        }
                        path.state = next
                    case .quoted(let units):
                        for unit in units.reversed() {
                            try push(.node(.literal(unit), depth + 1), onto: &path)
                        }
                    case .sequence(let nodes):
                        for child in nodes.reversed() {
                            try push(.node(child, depth + 1), onto: &path)
                        }
                    case .alternate(let nodes):
                        guard let first = nodes.first else {
                            continue backtrack
                        }
                        if nodes.count > 1 {
                            try fork([.alternative(nodes, 1, depth + 1)], from: path, into: &choices)
                        }
                        try push(.node(first, depth + 1), onto: &path)
                    case .capture(let id, let child):
                        try push(.capture(id, path.state.position), onto: &path)
                        try push(.node(child, depth + 1), onto: &path)
                    case .namedReference(let name):
                        guard
                            let id = compiled.names[name]?.first(where: {
                                path.state.captures[$0] != nil
                            })
                        else {
                            continue backtrack
                        }
                        try push(.node(.reference(id), depth + 1), onto: &path)
                    case .repeatNode(let child, let minimum, let maximum, let greedy, let possessive):
                        if possessive {
                            let accepted = try firstMatch(
                                .repeatNode(child, minimum, maximum, greedy, false),
                                path.state,
                                depth: depth + 1
                            )
                            if accepted == nil && lastRegionPruned {
                                // 原子区域失败时的 PRUNE 控制仍约束外层旧候选，不能重新尝试被撤销的路径。
                                trim(&choices, throughAlternative: false)
                                pruned = true
                            }
                            guard let accepted else {
                                continue backtrack
                            }
                            try acceptAtomic(accepted, path: &path, choices: &choices)
                        }
                        else {
                            try push(
                                .repetition(
                                    RegexRepeat(
                                        child: child,
                                        minimum: minimum,
                                        maximum: maximum,
                                        greedy: greedy,
                                        depth: depth
                                    )
                                ),
                                onto: &path
                            )
                        }
                    case .assertion(let child, let positive, let behind):
                        let accepted = try assertion(
                            child,
                            positive: positive,
                            behind: behind,
                            state: path.state,
                            depth: depth + 1
                        )
                        if lastRegionThen && accepted?.accepted != true {
                            // 普通断言的 THEN 会撤销外层最近分支资格，不能将其当作负向断言成功。
                            trim(&choices, throughAlternative: true)
                            thenEncountered = true
                            continue backtrack
                        }
                        guard let accepted else {
                            continue backtrack
                        }
                        path.state = accepted
                    case .atomic(let child):
                        let accepted = try firstMatch(child, path.state, depth: depth + 1)
                        if accepted == nil && lastRegionPruned {
                            trim(&choices, throughAlternative: false)
                            pruned = true
                        }
                        guard let accepted else {
                            continue backtrack
                        }
                        try acceptAtomic(accepted, path: &path, choices: &choices)
                    case .resetStart:
                        path.state.start = path.state.position
                    case .recurse(let id):
                        guard let child = id == 0 ? compiled.root : compiled.groups[id] else {
                            throw NateError.message("未知正则子程序 \(id)。")
                        }
                        try push(.subroutine(path.state.captures, path.state.currentRecursion), onto: &path)
                        path.state.currentRecursion = id
                        try push(.node(child, depth + 1), onto: &path)
                    case .namedRecurse(let name):
                        guard let id = compiled.names[name]?.first else {
                            throw NateError.message("未知正则子程序名称。")
                        }
                        try push(.node(.recurse(id), depth + 1), onto: &path)
                    case .conditional(let condition, let yes, let no):
                        let accepted = try conditionState(condition, state: path.state, depth: depth + 1)
                        path.state = accepted ?? path.state
                        try push(.node(accepted == nil ? no : yes, depth + 1), onto: &path)
                    case .flags(let sensitive, let dot, let multiline, let child):
                        try push(
                            .modes(path.state.sensitive, path.state.dot, path.state.multiline),
                            onto: &path
                        )
                        path.state.sensitive = sensitive ?? path.state.sensitive
                        path.state.dot = dot ?? path.state.dot
                        path.state.multiline = multiline ?? path.state.multiline
                        try push(.node(child, depth + 1), onto: &path)
                    case .control(let verb):
                        switch verb {
                        case .fail:
                            continue backtrack
                        case .accept:
                            path.state.accepted = true
                        case .then:
                            trim(&choices, throughAlternative: true)
                            thenEncountered = true
                        case .prune, .skip, .commit:
                            // 控制点之前的候选不再具有回退资格，后续表达式仍可产生自己的局部候选。
                            trim(&choices, throughAlternative: false)
                            pruned = true
                            if verb == .commit {
                                restart = .stop
                            }
                            else if verb == .skip && path.state.position != scanStart {
                                restart = .position(path.state.position)
                            }
                        }
                    }
                }
            }
            if let end, path.state.position > end {
                continue
            }
            if let requiredEnd, !path.state.accepted, path.state.position != requiredEnd {
                continue
            }
            return path.state
        }
        return nil
    }

    /// 业务作用：在独立回溯区域检查前后查找，正向断言保留捕获但不消费外部位置。
    /// 参数说明:
    /// - child: 断言内部表达式。
    /// - positive: 是否要求内部成功。
    /// - behind: 固定 UTF-16 回看长度，为空时是前向查找。
    /// - state: 外部位置与捕获。
    /// - depth: 当前调用深度。
    /// 返回：断言成立后的外部状态，失败时为空。
    mutating func assertion(_ child: RegexNode, positive: Bool, behind: Int?, state: MatchState, depth: Int)
        throws -> MatchState?
    {
        lastRegionThen = false
        var probe = state
        if let behind {
            guard state.position >= behind else {
                return positive ? nil : state
            }
            probe.position -= behind
        }
        let matched = try firstMatch(
            child,
            probe,
            depth: depth,
            requiredEnd: behind == nil ? nil : state.position
        )
        if var accepted = matched, accepted.accepted {
            accepted.position = state.position
            return accepted
        }
        if positive, var accepted = matched {
            accepted.position = state.position
            return accepted
        }
        return !positive && matched == nil ? state : nil
    }

    /// 业务作用：条件表达式只执行被选中的分支，未参与捕获与空捕获保持不同状态。
    /// 参数说明:
    /// - condition: 捕获、命名捕获、断言或定义块条件。
    /// - state: 当前可见捕获及正文位置。
    /// - depth: 当前条件的调用深度。
    /// 返回：条件成立时提供可继续的状态，定义块或条件不成立时为空。
    mutating func conditionState(_ condition: RegexCondition, state: MatchState, depth: Int) throws
        -> MatchState?
    {
        switch condition {
        case .capture(let id): return state.captures[id] == nil ? nil : state
        case .named(let name):
            return compiled.names[name]?.contains(where: {
                state.captures[$0] != nil
            }) == true ? state : nil
        case .assertion(let expression):
            guard case .assertion(let child, let positive, let behind) = expression else {
                throw NateError.message("条件断言缺少独立的查找规则。")
            }
            var accepted = try assertion(
                child,
                positive: positive,
                behind: behind,
                state: state,
                depth: depth
            )
            // 条件谓词的提前接受只确认条件，后续仍须执行选定分支。
            accepted?.accepted = false
            return accepted
        case .definition: return nil
        case .recursion(let id):
            guard let current = state.currentRecursion else {
                return nil
            }
            return id == nil || id == current ? state : nil
        case .namedRecursion(let name):
            guard let current = state.currentRecursion else {
                return nil
            }
            return compiled.names[name]?.contains(current) == true ? state : nil
        }
    }
}
