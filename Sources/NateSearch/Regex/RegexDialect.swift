import Foundation
import NateCore

indirect enum RegexNode: Sendable {
    case empty
    case literal(UInt16)
    case any, linebreak
    case anchor(String)
    case characterClass(String, Bool, [ClosedRange<UInt16>])
    case sequence([RegexNode])
    case alternate([RegexNode])
    case capture(Int, RegexNode)
    case reference(Int)
    case repeatNode(RegexNode, Int, Int, Bool, Bool)
    case assertion(RegexNode, Bool, Int?)
    case atomic(RegexNode)
    case resetStart
    case recurse(Int)
    case conditional(Int, RegexNode, RegexNode)
    case flags(Bool?, Bool?, RegexNode)
}

struct CompiledRegex: Sendable {
    var root: RegexNode
    var names: [String: Int]
    var groups: [Int: RegexNode]
}

struct RegexParser {
    let units: [UInt16]
    var index = 0
    var count = 0
    var names: [String: Int] = [:]
    var groups: [Int: RegexNode] = [:]

    /// 业务作用：编译 Boost 风格表达式，非法语法在任何修改前失败。
    /// 参数说明:
    /// - pattern: 原始正则文本。
    /// 返回：携带捕获和子程序定义的有界执行树。
    static func compile(_ pattern: String) throws -> CompiledRegex {
        var parser = RegexParser(units: Array(pattern.utf16))
        guard parser.units.count <= 1_000_000 else {
            throw NateError.message("表达式超过 1 MB 限额。")
        }
        let root = try parser.expression(depth: 0)
        guard parser.index == parser.units.count else {
            throw NateError.message("正则位置 \(parser.index + 1)：括号不匹配。")
        }
        return CompiledRegex(root: root, names: parser.names, groups: parser.groups)
    }

    /// 业务作用：解析分支和串联，限制表达式嵌套避免栈耗尽。
    /// 参数说明:
    /// - depth: 当前语法嵌套深度。
    /// 返回：保留左到右匹配优先级的语法树。
    mutating func expression(depth: Int) throws -> RegexNode {
        guard depth < 128 else {
            throw NateError.message("正则嵌套超过 128 层。")
        }
        var branches: [RegexNode] = []
        var sequence: [RegexNode] = []
        while index < units.count && units[index] != 41 {
            if take(124) {
                branches.append(.sequence(sequence))
                sequence = []
                continue
            }
            var node = try atom(depth: depth)
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
                        guard take(125), maximum >= minimum, minimum <= 1_000_000 else {
                            throw NateError.message("正则位置 \(start)：重复范围无效。")
                        }
                        bounds = (minimum, maximum)
                    }
                    else {
                        index = start - 1
                    }
                }
                if let bounds {
                    let lazy = take(63)
                    let possessive = !lazy && take(43)
                    node = .repeatNode(node, bounds.0, bounds.1, !lazy, possessive)
                }
            }
            sequence.append(node)
        }
        branches.append(.sequence(sequence))
        return branches.count == 1 ? branches[0] : .alternate(branches)
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
        case 40:
            var group: Int?
            var assertion: (Bool, Bool)?
            var atomic = false
            if take(63) {
                if take(58) {
                }
                else if take(61) {
                    assertion = (true, false)
                }
                else if take(33) {
                    assertion = (false, false)
                }
                else if take(62) {
                    atomic = true
                }
                else if take(60) {
                    if take(61) {
                        assertion = (true, true)
                    }
                    else if take(33) {
                        assertion = (false, true)
                    }
                    else {
                        let name = try readUntil(62)
                        count += 1
                        group = count
                        names[name] = count
                    }
                }
                else if take(39) {
                    let name = try readUntil(39)
                    count += 1
                    group = count
                    names[name] = count
                }
                else if take(82) || take(48) {
                    guard take(41) else {
                        throw diagnostic("递归调用缺少右括号")
                    }
                    return .recurse(0)
                }
                else if let number = number() {
                    guard take(41) else {
                        throw diagnostic("子程序调用缺少右括号")
                    }
                    return .recurse(number)
                }
                else {
                    var sensitive: Bool?
                    var dot: Bool?
                    var enabled = true
                    while index < units.count && units[index] != 58 && units[index] != 41 {
                        let flag = units[index]
                        index += 1
                        if flag == 45 {
                            enabled = false
                        }
                        else if flag == 105 {
                            sensitive = !enabled
                        }
                        else if flag == 115 {
                            dot = enabled
                        }
                        else if flag != 109 {
                            throw diagnostic("无法识别的模式开关")
                        }
                    }
                    if take(41) {
                        let remainder = try expression(depth: depth + 1)
                        return .flags(sensitive, dot, remainder)
                    }
                    guard take(58) else {
                        throw diagnostic("模式组缺少冒号")
                    }
                    let inside = try expression(depth: depth + 1)
                    guard take(41) else {
                        throw diagnostic("模式组未闭合")
                    }
                    return .flags(sensitive, dot, inside)
                }
            }
            else {
                count += 1
                group = count
            }
            let inside = try expression(depth: depth + 1)
            guard take(41) else {
                throw diagnostic("分组未闭合")
            }
            if let assertion {
                let width = assertion.1 ? fixedWidth(inside) : nil
                if assertion.1 && width == nil {
                    throw diagnostic("Lookbehind 必须使用固定长度")
                }
                return .assertion(inside, assertion.0, width)
            }
            if atomic {
                return .atomic(inside)
            }
            if let group {
                groups[group] = inside
                return .capture(group, inside)
            }
            return inside
        case 42, 43, 63: throw diagnostic("重复符号前缺少表达式")
        default: return .literal(value)
        }
    }

    /// 业务作用：解析转义但不借用 Foundation 的不同正则方言。
    /// 参数说明:
    /// - inClass: 当前是否处于字符类。
    /// 返回：对应语法单元，未知字母转义明确失败。
    mutating func escape(inClass: Bool) throws -> RegexNode {
        guard index < units.count else {
            throw diagnostic("末尾反斜杠未完成")
        }
        let c = units[index]
        index += 1
        if c >= 49 && c <= 57 {
            index -= 1
            return .reference(number() ?? 0)
        }
        switch c {
        case 110: return .literal(10)
        case 114: return .literal(13)
        case 116: return .literal(9)
        case 48: return .literal(0)
        case 97: return .literal(7)
        case 101: return .literal(27)
        case 102: return .literal(12)
        case 100, 68, 119, 87, 115, 83, 104, 72, 118, 86:
            return .characterClass(String(decoding: [c], as: UTF16.self), false, [])
        case 98: return inClass ? .literal(8) : .anchor("b")
        case 66, 65, 90, 122, 71: return .anchor(String(decoding: [c], as: UTF16.self))
        case 82: return .linebreak
        case 75: return .resetStart
        case 120, 117:
            let width = c == 120 ? 2 : 4
            let braced = take(123)
            let digits: String
            if braced {
                digits = try readUntil(125)
            }
            else {
                guard index + width <= units.count else {
                    throw diagnostic("字符码不完整")
                }
                digits = String(decoding: units[index..<(index + width)], as: UTF16.self)
                index += width
            }
            guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw diagnostic("字符码无效")
            }
            return .sequence(
                String(scalar).utf16.map {
                    .literal($0)
                }
            )
        case 107, 103:
            let closing: UInt16
            if take(60) {
                closing = 62
            }
            else if take(39) {
                closing = 39
            }
            else if take(123) {
                closing = 125
            }
            else {
                throw diagnostic("引用缺少名称界定符")
            }
            let name = try readUntil(closing)
            guard let number = Int(name) ?? names[name] else {
                throw diagnostic("未知捕获名称")
            }
            return .reference(number)
        default:
            if (65...90).contains(c) || (97...122).contains(c) {
                throw diagnostic("未识别的转义 \\" + String(decoding: [c], as: UTF16.self))
            }
            return .literal(c)
        }
    }

    /// 业务作用：解析字符集合及取反，范围端点保持 UTF-16 单元语义。
    /// 参数说明: 无。
    /// 返回：字符类；未闭合时失败。
    mutating func characterClass() throws -> RegexNode {
        let inverted = take(94)
        var ranges: [ClosedRange<UInt16>] = []
        var kinds = ""
        while index < units.count && units[index] != 93 {
            var node: RegexNode
            if take(92) {
                node = try escape(inClass: true)
            }
            else {
                node = .literal(units[index])
                index += 1
            }
            if case .characterClass(let kind, _, _) = node {
                kinds += kind
            }
            else if case .literal(let a) = node {
                if index + 1 < units.count && units[index] == 45 && units[index + 1] != 93 {
                    index += 1
                    let b = units[index]
                    index += 1
                    guard a <= b else {
                        throw diagnostic("字符范围倒置")
                    }
                    ranges.append(a...b)
                }
                else {
                    ranges.append(a...a)
                }
            }
        }
        guard take(93) else {
            throw diagnostic("字符类未闭合")
        }
        return .characterClass(kinds, inverted, ranges)
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
        case .empty, .anchor, .assertion, .resetStart: return 0
        case .capture(_, let n), .atomic(let n), .flags(_, _, let n): return fixedWidth(n)
        case .sequence(let nodes):
            let widths = nodes.compactMap(fixedWidth)
            return widths.count == nodes.count ? widths.reduce(0, +) : nil
        case .alternate(let nodes):
            let widths = nodes.compactMap(fixedWidth)
            return widths.count == nodes.count && Set(widths).count == 1 ? widths.first : nil
        case .repeatNode(let n, let a, let b, _, _):
            return a == b
                ? fixedWidth(n).map {
                    $0 * a
                } : nil
        default: return nil
        }
    }
}
