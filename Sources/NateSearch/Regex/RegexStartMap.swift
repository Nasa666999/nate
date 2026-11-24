import Foundation

extension CancellableMatcher {
    /// 业务作用：保留 Boost 对组合单元表达式的起点筛选，分支和重复不能凭额外候选改变首个命中。
    /// 参数说明:
    /// - node: 即将进入的表达式。
    /// - state: 候选起点及当前大小写规则。
    /// - following: 当前表达式结束后的外层续接。
    /// 返回：候选符合原起点表时为真；所有遍历共用匹配预算，超限或撤权直接失败。
    mutating func canStart(
        _ node: RegexNode,
        state: MatchState,
        following: [RegexInstruction] = []
    ) throws -> Bool {
        guard compiled.usesCombining else {
            return true
        }
        // 原起点表只有 256 个条目，宽字符直接进入实际匹配，不能把筛选扩展到 Unicode 全域。
        if state.position < inputEnd && input[state.position] >= 256 {
            return true
        }
        return try startMap(following, node: node, state: state, depth: 0)
    }

    /// 业务作用：解释有限起点表所需的前沿，不消费正文、不改变捕获，也不执行控制动词。
    /// 参数说明:
    /// - instructions: 从栈顶开始解释的前沿及外层续接。
    /// - node: 先于外层续接解释的表达式，为空时只解释已有前沿。
    /// - state: 原候选位置与局部模式。
    /// - depth: 分支展开深度。
    /// 返回：当前 UTF-16 单元或末端可进入前沿时为真；计算受整次搜索的共享额度约束。
    private mutating func startMap(
        _ instructions: [RegexInstruction],
        node: RegexNode? = nil,
        state: MatchState,
        depth: Int
    ) throws -> Bool {
        guard depth < 256 else {
            return true
        }
        // 先登记全部续接再触发数组写时复制，筛选不能在已占满的回溯栈之外取得额外整份容量。
        try reserve(paths: 1, instructions: instructions.count + (node == nil ? 0 : 1))
        var pending = instructions
        if let node {
            pending.append(.node(node, 0))
        }
        defer {
            retainedPaths -= 1
            retainedInstructions -= pending.count
        }
        var state = state
        while let instruction = pending.popLast() {
            retainedInstructions -= 1
            try checkpoint()
            switch instruction {
            case .modes(let sensitive, let dot, let multiline):
                state.sensitive = sensitive
                state.dot = dot
                state.multiline = multiline
            case .capture, .acceptedBranches, .alternative, .resetAlternative, .subroutine:
                continue
            case .repeated:
                return true
            case .repetition(let repetition):
                try startPush(
                    .node(
                        .repeatNode(
                            repetition.child,
                            max(0, repetition.minimum - repetition.count),
                            max(0, repetition.maximum - repetition.count),
                            repetition.greedy,
                            false
                        ),
                        0
                    ),
                    onto: &pending
                )
            case .node(let node, _):
                switch node {
                case .directive, .empty, .combining, .resetStart:
                    continue
                case .literal(let unit):
                    return state.position < inputEnd
                        && equal(input[state.position], unit, sensitive: state.sensitive)
                case .quoted(let units):
                    if let unit = units.first {
                        return state.position < inputEnd
                            && equal(input[state.position], unit, sensitive: state.sensitive)
                    }
                case .any:
                    return state.position < inputEnd
                case .linebreak, .characterClass:
                    return try consume(node, state) != nil
                case .reference, .namedReference:
                    return true
                case .recurse(let id):
                    if let child = id == 0 ? compiled.root : compiled.groups[id] {
                        return try startMap(pending, node: child, state: state, depth: depth + 1)
                    }
                    return true
                case .namedRecurse(let name):
                    if let id = compiled.names[name]?.first, let child = compiled.groups[id] {
                        return try startMap(pending, node: child, state: state, depth: depth + 1)
                    }
                    return true
                case .sequence(let nodes):
                    for child in nodes.reversed() {
                        try checkpoint()
                        try startPush(.node(child, 0), onto: &pending)
                    }
                case .alternate(let nodes), .resetAlternate(let nodes):
                    for child in nodes {
                        if try startMap(pending, node: child, state: state, depth: depth + 1) {
                            return true
                        }
                    }
                    return false
                case .capture(_, let child):
                    try startPush(.node(child, 0), onto: &pending)
                case .repeatNode(let child, let minimum, let maximum, _, _):
                    if maximum > 0 {
                        if try startMap(
                            [],
                            node: child,
                            state: state,
                            depth: depth + 1
                        ) {
                            return true
                        }
                    }
                    if minimum > 0 {
                        return false
                    }
                case .assertion:
                    return true
                case .atomic(let child):
                    return try startMap([.node(child, 0)], state: state, depth: depth + 1)
                case .conditional(_, let yes, let no):
                    if try startMap(pending, node: yes, state: state, depth: depth + 1) {
                        return true
                    }
                    try startPush(.node(no, 0), onto: &pending)
                case .flags(let sensitive, let dot, let multiline, let child):
                    try startPush(.modes(state.sensitive, state.dot, state.multiline), onto: &pending)
                    state.sensitive = sensitive ?? state.sensitive
                    state.dot = dot ?? state.dot
                    state.multiline = multiline ?? state.multiline
                    try startPush(.node(child, 0), onto: &pending)
                case .anchor(let anchor):
                    if anchor == "z" {
                        return state.position == inputEnd
                    }
                    if anchor == "$" {
                        return state.position == inputEnd
                            || [10, 13, 12, 0x85].contains(input[state.position])
                    }
                case .control(let verb):
                    if verb == .accept || verb == .commit || verb == .prune || verb == .skip {
                        return true
                    }
                }
            }
        }
        return true
    }

    /// 业务作用：前沿展开前登记单个续接，计算撤销或配额不足时保持可完整释放的状态。
    /// 参数说明:
    /// - instruction: 将要解释的筛选步骤。
    /// - pending: 当前已登记的前沿栈。
    /// 返回：仅在共享预算允许时保留该步骤，失败时不增加栈内容。
    private mutating func startPush(_ instruction: RegexInstruction, onto pending: inout [RegexInstruction])
        throws
    {
        try checkpoint()
        try reserve(paths: 0, instructions: 1)
        pending.append(instruction)
    }
}
