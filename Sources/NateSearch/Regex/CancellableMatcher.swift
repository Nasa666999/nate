import Foundation
import NateCore

struct MatchState {
    var position: Int
    var start: Int
    var captures: [Int: NSRange] = [:]
    var sensitive: Bool
    var dot: Bool
    var multiline = true
    var accepted = false
    var currentRecursion: Int?
    var lastClosedCapture: Int?
}

struct CancellableMatcher {
    let input: [UInt16]
    let compiled: CompiledRegex
    let limit: Int
    let deadline: ContinuousClock.Instant
    var softEnd = 0
    var steps = 0
    var scanStart = 0
    var retainedPaths = 0
    var retainedInstructions = 0
    var restart = RegexRestart.next
    var lastRegionPruned = false
    var lastRegionThen = false
    var permit: @Sendable () -> Bool = {
        true
    }
    // 左侧真实正文可用于回看，前向证据仍不得越过本请求的上下文末端。
    var contextEnd: Int?
    var inputEnd: Int {
        min(contextEnd ?? input.count, input.count)
    }

    /// 业务作用：在每个执行步骤限制计算、内存和取消延迟。
    /// 参数说明: 无。
    /// 返回：超过预算或取消立即终止整次搜索，不伪装成无结果。
    mutating func checkpoint() throws {
        steps += 1
        guard steps <= limit else {
            throw NateError.message("搜索超过计算预算，请缩小范围或简化表达式。")
        }
        if steps == 1 || steps % 256 == 0 {
            try Task.checkCancellation()
            // 阻塞队列中的匹配没有 Swift Task 取消上下文，显式权限失效也必须停止实际回溯。
            guard permit() else {
                throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
                throw NateError.message("搜索超过 3 秒预算。")
            }
        }
    }

    /// 业务作用：执行单个确定性字符或边界条件，分支和回退由有界执行栈统一调度。
    /// 参数说明:
    /// - node: 字面、字符类、换行、锚点或已解析的捕获引用。
    /// - state: 当前输入位置、捕获与局部模式。
    /// 返回：条件满足时提供唯一后继；不满足时不消费正文，非法内部节点明确失败。
    mutating func consume(_ node: RegexNode, _ state: MatchState) throws -> MatchState? {
        var next = state
        switch node {
        case .literal(let value):
            guard state.position < inputEnd,
                equal(input[state.position], value, sensitive: state.sensitive)
            else {
                return nil
            }
            next.position += 1
            return next
        case .any:
            guard state.position < inputEnd,
                state.dot || ![10, 13, 0x85, 0x2028, 0x2029].contains(input[state.position])
            else {
                return nil
            }
            next.position += 1
            return next
        case .linebreak:
            guard state.position < inputEnd,
                [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(input[state.position])
            else {
                return nil
            }
            next.position +=
                input[state.position] == 13 && state.position + 1 < inputEnd
                    && input[state.position + 1] == 10 ? 2 : 1
            return next
        case .characterClass(let kinds, let inverted, let ranges):
            guard state.position < inputEnd else {
                return nil
            }
            let unit = input[state.position]
            var matches = false
            // 一个字符类也可能包含大量区间，每次分类工作必须计入同一执行预算，不能只在外层节点检查。
            for range in ranges {
                try checkpoint()
                if range.contains(unit) {
                    matches = true
                    break
                }
            }
            if !matches && !state.sensitive {
                let value = LiteralMatcher.fold(unit, sensitive: false)
                for range in ranges {
                    try checkpoint()
                    let lower = LiteralMatcher.fold(range.lowerBound, sensitive: false)
                    let upper = LiteralMatcher.fold(range.upperBound, sensitive: false)
                    if lower <= value && value <= upper {
                        matches = true
                        break
                    }
                }
            }
            for kind in kinds {
                // 字符类是并集，成员已确定后无需继续扫描；最终否定只对整个并集应用一次。
                if matches {
                    break
                }
                try checkpoint()
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
                case "l":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.lowercaseLetters.contains($0)
                        } ?? false
                case "u":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.uppercaseLetters.contains($0)
                        } ?? false
                case "a":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.letters.contains($0)
                        } ?? false
                case "n":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.alphanumerics.contains($0)
                        } ?? false
                case "t": hit = unit == 9 || unit == 32
                case "c":
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.controlCharacters.contains($0)
                        } ?? false
                case "g": hit = unit > 32 && unit != 127
                case "p": hit = unit >= 32 && unit != 127
                case "q":
                    hit =
                        (33...126).contains(unit) && !(48...57).contains(unit)
                        && !(65...90).contains(unit) && !(97...122).contains(unit)
                case "o": hit = unit > 127
                case "x":
                    hit = (48...57).contains(unit) || (65...70).contains(unit) || (97...102).contains(unit)
                default: break
                }
                if !state.sensitive && (lower == "l" || lower == "u") {
                    hit =
                        Unicode.Scalar(unit).map {
                            CharacterSet.letters.contains($0)
                        } ?? false
                }
                matches = matches || (String(kind) == lower ? hit : !hit)
            }
            guard matches != inverted else {
                return nil
            }
            next.position += 1
            return next
        case .anchor(let anchor):
            let p = state.position
            let before = p > 0 ? input[p - 1] : nil
            let after = p < inputEnd ? input[p] : nil
            let boundary = (before.map(word) ?? false) != (after.map(word) ?? false)
            let accepted: Bool
            switch anchor {
            case "^":
                accepted = p == 0 || state.multiline && (before == 10 || (before == 13 && after != 10))
            case "$":
                accepted =
                    p == inputEnd || state.multiline && (after == 13 || (after == 10 && before != 13))
            case "A": accepted = p == 0
            case "z": accepted = p == inputEnd
            case "Z": accepted = p >= softEnd
            case "G": accepted = p == scanStart
            case "b": accepted = boundary
            case "B": accepted = !boundary
            case "<": accepted = !(before.map(word) ?? false) && (after.map(word) ?? false)
            case ">": accepted = (before.map(word) ?? false) && !(after.map(word) ?? false)
            default: accepted = false
            }
            return accepted ? state : nil
        case .reference(let id):
            guard let range = state.captures[id], range.length <= inputEnd - state.position else {
                return nil
            }
            for i in 0..<range.length {
                try checkpoint()
                guard equal(input[range.location + i], input[state.position + i], sensitive: state.sensitive)
                else {
                    return nil
                }
            }
            next.position += range.length
            return next
        default:
            throw NateError.message("正则执行节点无法作为独立字符条件处理。")
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
