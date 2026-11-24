import Foundation
import NateCore

indirect enum RegexNode: Sendable {
    case directive
    case quoted([UInt16])
    case empty
    case literal(UInt16)
    case any, linebreak, combining
    case anchor(String)
    case characterClass(String, Bool, [ClosedRange<UInt16>])
    case sequence([RegexNode])
    case alternate([RegexNode])
    case resetAlternate([RegexNode])
    case capture(Int, RegexNode)
    case reference(Int)
    case namedReference(String)
    case repeatNode(RegexNode, Int, Int, Bool, Bool)
    case assertion(RegexNode, Bool, Int?)
    case atomic(RegexNode)
    case resetStart
    case recurse(Int)
    case namedRecurse(String)
    case conditional(RegexCondition, RegexNode, RegexNode)
    case flags(Bool?, Bool?, Bool?, RegexNode)
    case control(RegexVerb)
}

struct RegexModes {
    var sensitive: Bool
    var dot: Bool
    var multiline = true
    var extended = false
}

struct CompiledRegex: Sendable {
    var root: RegexNode
    var names: [String: [Int]]
    var groups: [Int: RegexNode]
    var usesCombining = false
}

struct RegexParser {
    let units: [UInt16]
    var modes: RegexModes
    var allowsLookbehind = true
    var index = 0
    var count = 0
    var names: [String: [Int]] = [:]
    var groups: [Int: RegexNode] = [:]
    var referencedGroups: [Int] = []
    var referencedNames: [String] = []
    var permit: @Sendable () -> Bool = {
        true
    }
    var compileDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    var compileSteps = 0
    var usesCombining = false

    /// 业务作用：编译 Boost 风格表达式，非法语法在任何修改前失败。
    /// 参数说明:
    /// - pattern: 原始正则文本。
    /// - caseSensitive: 搜索界面给出的初始大小写规则。
    /// - dotMatchesNewline: 搜索界面给出的初始点号规则。
    /// - allowsLookbehind: 调用方的规则格式是否允许后行断言。
    /// - permit: 调用方仍持有的计算权限，阻塞队列中也检查实际撤销。
    /// 返回：携带捕获和子程序定义的有界执行树。
    static func compile(
        _ pattern: String,
        caseSensitive: Bool,
        dotMatchesNewline: Bool,
        allowsLookbehind: Bool = true,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> CompiledRegex {
        try Task.checkCancellation()
        // 在建立字符投影前限制输入并复验调用权，已撤销请求不能继续派生大块内存。
        guard permit() else {
            throw CancellationError()
        }
        guard pattern.utf8.count <= 1_048_576 else {
            throw NateError.message("正则表达式超过 1 MiB UTF-8 输入限额。")
        }
        var parser = RegexParser(
            units: Array(pattern.utf16),
            modes: RegexModes(
                sensitive: caseSensitive,
                dot: dotMatchesNewline
            ),
            allowsLookbehind: allowsLookbehind,
            permit: permit
        )
        try parser.checkpoint(force: true)
        let root = try parser.expression(depth: 0)
        guard parser.index == parser.units.count else {
            throw NateError.message("正则位置 \(parser.index + 1)：括号不匹配。")
        }
        guard
            parser.referencedGroups.allSatisfy({
                $0 > 0 && $0 <= parser.count
            }),
            parser.referencedNames.allSatisfy({
                parser.names[$0] != nil
            })
        else {
            throw parser.diagnostic("引用指向不存在的捕获")
        }
        try parser.checkpoint(force: true)
        return CompiledRegex(
            root: root,
            names: parser.names,
            groups: parser.groups,
            usesCombining: parser.usesCombining
        )
    }

    /// 业务作用：编译扫描与树构建共用有界预算，注释、字符类和引用块也不能绕过取消。
    /// 参数说明:
    /// - force: 是否立即复验显式令牌及实际截止。
    /// 返回：超过 262144 个扫描步骤、两秒截止或失去调用权时停止编译，不进入匹配阶段。
    mutating func checkpoint(force: Bool = false) throws {
        compileSteps += 1
        guard compileSteps <= 262_144 else {
            throw NateError.message("正则编译超过 262144 个扫描步骤预算。")
        }
        if force || compileSteps & 255 == 0 {
            try Task.checkCancellation()
            // I/O 队列不继承 Swift Task 的取消上下文，显式令牌必须在解析器内部独立复验。
            guard permit() else {
                throw CancellationError()
            }
            guard ContinuousClock.now < compileDeadline else {
                throw NateError.message("正则编译超过 2 秒预算。")
            }
        }
    }

    /// 业务作用：解析分支和串联，限制表达式嵌套避免栈耗尽。
    /// 参数说明:
    /// - depth: 当前语法嵌套深度。
    /// - resettingCaptures: 当前组的各分支是否从相同捕获编号继续。
    /// 返回：保留左到右匹配优先级的语法树；分支重置组之后的编号沿全部分支的最大值继续。
    mutating func expression(depth: Int, resettingCaptures: Bool = false) throws -> RegexNode {
        guard depth < 128 else {
            throw NateError.message("正则嵌套超过 128 层。")
        }
        let outerModes = modes
        defer {
            modes = outerModes
        }
        var branches: [RegexNode] = []
        var sequence: [RegexNode] = []
        let captureBase = count
        var captureMaximum = count
        while index < units.count {
            try checkpoint()
            try skipTrivia()
            guard index < units.count, units[index] != 41 else {
                break
            }
            if take(124) {
                branches.append(.sequence(sequence))
                sequence = []
                if resettingCaptures {
                    captureMaximum = max(captureMaximum, count)
                    count = captureBase
                }
                continue
            }
            var node = try atom(depth: depth)
            if case .directive = node {
                continue
            }
            if case .quoted(let literals) = node {
                // 引用块仍是连续字面字符；紧随其后的重复符只约束最后一个字符。
                sequence += literals.dropLast().map {
                    .flags(modes.sensitive, modes.dot, modes.multiline, .literal($0))
                }
                node =
                    literals.last.map {
                        .literal($0)
                    } ?? .empty
            }
            try skipTrivia()
            if index < units.count {
                var bounds: (Int, Int)?
                if take(42) {
                    bounds = (0, Int.max)
                }
                else if take(43) {
                    bounds = (1, Int.max)
                }
                else if take(63) {
                    bounds = (0, 1)
                }
                else if take(123) {
                    let start = index
                    let minimum = number()
                    if let minimum {
                        var maximum = minimum
                        if take(44) {
                            maximum = number() ?? Int.max
                        }
                        if !take(125) {
                            index = start - 1
                        }
                        else {
                            guard maximum >= minimum, minimum <= 1_000_000 else {
                                throw NateError.message("正则位置 \(start)：重复范围无效。")
                            }
                            bounds = (minimum, maximum)
                        }
                    }
                    else {
                        index = start - 1
                    }
                }
                if let bounds {
                    try skipTrivia()
                    let lazy = take(63)
                    let possessive = !lazy && take(43)
                    node = .repeatNode(node, bounds.0, bounds.1, !lazy, possessive)
                }
            }
            sequence.append(.flags(modes.sensitive, modes.dot, modes.multiline, node))
        }
        branches.append(.sequence(sequence))
        if resettingCaptures {
            count = max(captureMaximum, count)
        }
        if resettingCaptures && branches.count > 1 {
            return .resetAlternate(branches)
        }
        return branches.count == 1 ? branches[0] : .alternate(branches)
    }

    /// 业务作用：忽略不参与匹配的注释，扩展模式下同时忽略类外空白与行尾注释。
    /// 参数说明: 无。
    /// 返回：停在下一个语法单元；内联注释没有终止符时消费剩余表达式。
    mutating func skipTrivia() throws {
        while index < units.count {
            try checkpoint()
            if index + 2 < units.count, units[index] == 40,
                units[index + 1] == 63, units[index + 2] == 35
            {
                index += 3
                while index < units.count, units[index] != 41 {
                    try checkpoint()
                    index += 1
                }
                _ = take(41)
            }
            else if modes.extended, [9, 10, 11, 12, 13, 32].contains(units[index]) {
                index += 1
            }
            else if modes.extended, units[index] == 35 {
                while index < units.count, ![10, 13].contains(units[index]) {
                    try checkpoint()
                    index += 1
                }
            }
            else {
                break
            }
        }
    }

    /// 业务作用：解析字符、断言、捕获、递归和控制结构的独立单元。
    /// 参数说明:
    /// - depth: 外层嵌套深度。
    /// 返回：一个完整的匹配单元。
    mutating func atom(depth: Int) throws -> RegexNode {
        let value = units[index]
        index += 1
        switch value {
        case 46: return .any
        case 94: return .anchor("^")
        case 36: return .anchor("$")
        case 92: return try escape(inClass: false)
        case 91: return try characterClass()
        case 40: return try group(depth: depth)
        case 42, 43, 63: throw diagnostic("重复符号前缺少表达式")
        default: return .literal(value)
        }
    }

    /// 业务作用：消费单个结构标记，保持解析位置可诊断。
    /// 参数说明:
    /// - value: 期望的 UTF-16 单元。
    /// 返回：匹配时推进一位。
    mutating func take(_ value: UInt16) -> Bool {
        guard index < units.count, units[index] == value else {
            return false
        }
        index += 1
        return true
    }

    /// 业务作用：读取有界十进制参数，拒绝整数溢出。
    /// 参数说明: 无。
    /// 返回：没有数字时为空。
    mutating func number() -> Int? {
        let start = index
        while index < units.count && (48...57).contains(units[index]) {
            index += 1
        }
        return start < index ? Int(String(decoding: units[start..<index], as: UTF16.self)) : nil
    }

    /// 业务作用：读取捕获名或字符码直至明确终止符。
    /// 参数说明:
    /// - end: 终止标记。
    /// 返回：不包含终止符的文本；缺少终止符时失败。
    mutating func readUntil(_ end: UInt16) throws -> String {
        let start = index
        while index < units.count && units[index] != end {
            try checkpoint()
            index += 1
        }
        let value = String(decoding: units[start..<index], as: UTF16.self)
        guard take(end) else {
            throw diagnostic("结构未闭合")
        }
        return value
    }

    /// 业务作用：将语法失败关联到用户表达式位置。
    /// 参数说明:
    /// - message: 具体失败原因。
    /// 返回：可展示错误。
    func diagnostic(_ message: String) -> NateError {
        .message("正则 UTF-16 位置 \(index + 1)：\(message)。")
    }

    /// 业务作用：验证 Lookbehind 固定长度，不接受可变长度替代语义。
    /// 参数说明:
    /// - node: 待验证子树。
    /// 返回：固定 UTF-16 长度；不固定时为空。
    func fixedWidth(_ node: RegexNode) -> Int? {
        switch node {
        case .literal, .any, .characterClass: return 1
        case .quoted(let units): return units.count
        case .directive, .empty, .anchor, .assertion, .resetStart, .control: return 0
        case .capture(_, let n), .atomic(let n), .flags(_, _, _, let n): return fixedWidth(n)
        case .sequence(let nodes):
            let widths = nodes.compactMap(fixedWidth)
            guard widths.count == nodes.count else {
                return nil
            }
            var total = 0
            for width in widths {
                let sum = total.addingReportingOverflow(width)
                guard !sum.overflow else {
                    return nil
                }
                total = sum.partialValue
            }
            return total
        case .alternate(let nodes), .resetAlternate(let nodes):
            let widths = nodes.compactMap(fixedWidth)
            return widths.count == nodes.count && Set(widths).count == 1 ? widths.first : nil
        case .repeatNode(let n, let a, let b, _, _):
            guard a == b, let width = fixedWidth(n) else {
                return nil
            }
            let product = width.multipliedReportingOverflow(by: a)
            return product.overflow ? nil : product.partialValue
        default: return nil
        }
    }
}
