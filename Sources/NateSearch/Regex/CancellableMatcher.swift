import Foundation
import NateCore

struct MatchState {
    var position: Int
    var start: Int
    var captures: [Int: NSRange] = [:]
    var sensitive: Bool
    var dot: Bool
}

struct CancellableMatcher {
    let input: [UInt16]
    let compiled: CompiledRegex
    let limit: Int
    let deadline: ContinuousClock.Instant
    var steps = 0
    var scanStart = 0

    /// 业务作用：在每个执行步骤限制计算、内存和取消延迟。
    /// 参数说明: 无。
    /// 返回：超过预算或取消立即终止整次搜索，不伪装成无结果。
    mutating func checkpoint() throws {
        steps += 1
        guard steps <= limit else {
            throw NateError.message("搜索超过计算预算，请缩小范围或简化表达式。")
        }
        if steps % 256 == 0 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("搜索超过 3 秒预算。")
            }
        }
    }

    /// 业务作用：按分支优先级执行语法树，所有回溯都受统一预算约束。
    /// 参数说明:
    /// - node: 当前语法节点。
    /// - state: 输入位置、捕获与局部模式。
    /// - depth: 递归深度。
    /// 返回：按优先级排列的可行后继状态。
    mutating func run(_ node: RegexNode, _ state: MatchState, depth: Int = 0) throws -> [MatchState] {
        try checkpoint()
        guard depth < 256 else {
            throw NateError.message("正则递归超过 256 层。")
        }
        var next = state
        switch node {
        case .empty: return [state]
        case .literal(let value):
            guard state.position < input.count,
                equal(input[state.position], value, sensitive: state.sensitive)
            else {
                return []
            }
            next.position += 1
            return [next]
        case .any:
            guard state.position < input.count,
                state.dot || ![10, 13, 0x85, 0x2028, 0x2029].contains(input[state.position])
            else {
                return []
            }
            next.position += 1
            return [next]
        case .linebreak:
            guard state.position < input.count,
                [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(input[state.position])
            else {
                return []
            }
            next.position +=
                input[state.position] == 13 && state.position + 1 < input.count
                    && input[state.position + 1] == 10 ? 2 : 1
            return [next]
        case .characterClass(let kinds, let inverted, let ranges):
            guard state.position < input.count else {
                return []
            }
            let unit = input[state.position]
            var matches = ranges.contains {
                $0.contains(unit)
            }
            if !state.sensitive {
                matches =
                    matches
                    || ranges.contains {
                        range in
                        equal(range.lowerBound, unit, sensitive: false)
                            || equal(range.upperBound, unit, sensitive: false)
                    }
            }
            for kind in kinds {
                let lower = String(kind).lowercased()
                var hit = false
                switch lower {
                case "d": hit = (48...57).contains(unit)
                case "w": hit = word(unit)
                case "s":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.whitespacesAndNewlines.contains($0)
                        } ?? false
                case "h":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.whitespaces.contains($0)
                        } ?? false
                case "v": hit = [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(unit)
                default: break
                }
                matches = matches || (String(kind) == lower ? hit : !hit)
            }
            guard matches != inverted else {
                return []
            }
            next.position += 1
            return [next]
        case .anchor(let anchor):
            let p = state.position
            let before = p > 0 ? input[p - 1] : nil
            let after = p < input.count ? input[p] : nil
            let boundary = (before.map(word) ?? false) != (after.map(word) ?? false)
            let accepted: Bool
            switch anchor {
            case "^": accepted = p == 0 || before == 10 || (before == 13 && after != 10)
            case "$": accepted = p == input.count || after == 13 || (after == 10 && before != 13)
            case "A": accepted = p == 0
            case "z": accepted = p == input.count
            case "Z": accepted = p == input.count || p == input.count - 1 && [10, 13].contains(after ?? 0)
            case "G": accepted = p == scanStart
            case "b": accepted = boundary
            case "B": accepted = !boundary
            default: accepted = false
            }
            return accepted ? [state] : []
        case .sequence(let nodes):
            var states = [state]
            for child in nodes {
                var output: [MatchState] = []
                for s in states {
                    output += try run(child, s, depth: depth + 1)
                    guard output.count <= 100_000 else {
                        throw NateError.message("正则回溯状态超过内存预算。")
                    }
                }
                states = output
                if states.isEmpty {
                    break
                }
            }
            return states
        case .alternate(let nodes):
            var result: [MatchState] = []
            for child in nodes {
                result += try run(child, state, depth: depth + 1)
            }
            return result
        case .capture(let id, let child):
            return try run(child, state, depth: depth + 1).map {
                s in
                var s = s
                s.captures[id] = NSRange(location: state.position, length: s.position - state.position)
                return s
            }
        case .reference(let id):
            guard let range = state.captures[id], range.length <= input.count - state.position else {
                return []
            }
            for i in 0..<range.length {
                try checkpoint()
                guard equal(input[range.location + i], input[state.position + i], sensitive: state.sensitive)
                else {
                    return []
                }
            }
            next.position += range.length
            return [next]
        case .repeatNode(let child, let minimum, let maximum, let greedy, let possessive):
            var levels = [[state]]
            let cap = min(maximum, input.count + 1)
            if cap > 0 {
                for _ in 0..<cap {
                    var level: [MatchState] = []
                    for s in levels[levels.count - 1] {
                        for n in try run(child, s, depth: depth + 1) {
                            if n.position != s.position {
                                level.append(n)
                            }
                            else if levels.count <= minimum {
                                level.append(n)
                            }
                        }
                    }
                    if level.isEmpty {
                        break
                    }
                    guard level.count <= 100_000 else {
                        throw NateError.message("重复匹配超过内存预算。")
                    }
                    levels.append(level)
                }
            }
            guard levels.count > minimum else {
                return []
            }
            let indices = greedy ? Array((minimum..<levels.count).reversed()) : Array(minimum..<levels.count)
            if possessive {
                return indices.first.flatMap {
                    levels[$0].first
                }.map {
                    [$0]
                } ?? []
            }
            return indices.flatMap {
                levels[$0]
            }
        case .assertion(let child, let positive, let behind):
            var probe = state
            if let behind {
                guard state.position >= behind else {
                    return positive ? [] : [state]
                }
                probe.position -= behind
            }
            let matches = try run(child, probe, depth: depth + 1).filter {
                behind == nil || $0.position == state.position
            }
            if positive, var accepted = matches.first {
                accepted.position = state.position
                return [accepted]
            }
            return !positive && matches.isEmpty ? [state] : []
        case .atomic(let child):
            return try run(child, state, depth: depth + 1).first.map {
                [$0]
            } ?? []
        case .resetStart:
            next.start = state.position
            return [next]
        case .recurse(let id):
            guard let child = id == 0 ? compiled.root : compiled.groups[id] else {
                throw NateError.message("未知正则子程序 \(id)。")
            }
            return try run(child, state, depth: depth + 1)
        case .conditional(let id, let yes, let no):
            return try run(state.captures[id] != nil ? yes : no, state, depth: depth + 1)
        case .flags(let sensitive, let dot, let child):
            next.sensitive = sensitive ?? state.sensitive
            next.dot = dot ?? state.dot
            return try run(child, next, depth: depth + 1).map {
                var result = $0
                result.sensitive = state.sensitive
                result.dot = state.dot
                return result
            }
        }
    }

    /// 业务作用：固定字面大小写比较，不进行规范等价归一化。
    /// 参数说明:
    /// - a: 实际 UTF-16 单元。
    /// - b: 期望 UTF-16 单元。
    /// - sensitive: 是否区分大小写。
    /// 返回：精确相等或单元大小写折叠相等。
    func equal(_ a: UInt16, _ b: UInt16, sensitive: Bool) -> Bool {
        if a == b {
            return true
        }
        guard !sensitive, let a = Unicode.Scalar(a), let b = Unicode.Scalar(b) else {
            return false
        }
        return String(a).lowercased().utf16.elementsEqual(String(b).lowercased().utf16)
    }

    /// 业务作用：统一全词与词边界的字符分类。
    /// 参数说明:
    /// - unit: UTF-16 字符单元。
    /// 返回：字母、数字和下划线属于词。
    func word(_ unit: UInt16) -> Bool {
        unit == 95
            || (Unicode.Scalar(unit).map {
                CharacterSet.alphanumerics.contains($0)
            } ?? false)
    }
}
