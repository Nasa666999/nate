import Foundation
import NateCore

extension RegexParser {
    /// 业务作用：解析转义但不借用 Foundation 的不同正则方言。
    /// 参数说明:
    /// - inClass: 当前是否处于字符类。
    /// 返回：对应语法单元；普通未知转义按字面字符处理，结构错误明确失败。
    mutating func escape(inClass: Bool) throws -> RegexNode {
        guard index < units.count else {
            throw diagnostic("末尾反斜杠未完成")
        }
        let c = units[index]
        index += 1
        if c >= 49 && c <= 57 {
            guard !inClass else {
                throw diagnostic("字符类中的八进制转义必须以零开头")
            }
            let id = Int(c - 48)
            referencedGroups.append(id)
            return .reference(id)
        }
        switch c {
        case 110: return .literal(10)
        case 114: return .literal(13)
        case 116: return .literal(9)
        case 48:
            var value: UInt16 = 0
            for _ in 0..<3 {
                guard index < units.count, (48...55).contains(units[index]) else {
                    break
                }
                value = value * 8 + units[index] - 48
                index += 1
            }
            return .literal(value)
        case 97: return .literal(7)
        case 101: return .literal(27)
        case 102: return .literal(12)
        case 118 where inClass: return .literal(11)
        case 100, 68, 119, 87, 115, 83, 104, 72, 118, 86, 108, 76, 117, 85:
            return .characterClass(String(decoding: [c], as: UTF16.self), false, [])
        case 98: return inClass ? .literal(8) : .anchor("b")
        case 66, 65, 90, 122, 71, 60, 62:
            return inClass ? .literal(c) : .anchor(String(decoding: [c], as: UTF16.self))
        case 82: return inClass ? .literal(c) : .linebreak
        case 75: return inClass ? .literal(c) : .resetStart
        case 99:
            guard index < units.count else {
                throw diagnostic("控制字符转义不完整")
            }
            let value = units[index] % 32
            index += 1
            return .literal(value)
        case 81 where !inClass:
            let start = index
            while index < units.count {
                if index + 1 < units.count, units[index] == 92, units[index + 1] == 69 {
                    let result = Array(units[start..<index])
                    index += 2
                    return .quoted(result)
                }
                index += 1
            }
            return .quoted(Array(units[start..<index]))
        case 112, 80:
            if inClass {
                return .literal(c)
            }
            let name: String
            if take(123) {
                name = try readUntil(125)
            }
            else {
                guard index < units.count else {
                    throw diagnostic("字符属性不完整")
                }
                name = String(decoding: [units[index]], as: UTF16.self)
                index += 1
            }
            return .characterClass(try classKind(name, inverted: c == 80), false, [])
        case 120:
            let braced = take(123)
            let digits: String
            if braced {
                digits = try readUntil(125)
            }
            else {
                let start = index
                while index < min(start + 2, units.count),
                    (48...57).contains(units[index]) || (65...70).contains(units[index])
                        || (97...102).contains(units[index])
                {
                    index += 1
                }
                digits = String(decoding: units[start..<index], as: UTF16.self)
            }
            guard let value = UInt16(digits, radix: 16) else {
                throw diagnostic("字符码无效")
            }
            return .literal(value)
        case 107, 103:
            if inClass {
                return .literal(c)
            }
            if index < units.count, [43, 45].contains(units[index]) || (48...57).contains(units[index]) {
                let negative = take(45)
                if !negative {
                    _ = take(43)
                }
                guard let number = number(), number > 0 else {
                    throw diagnostic("反向引用编号无效")
                }
                let id = negative ? count - number + 1 : number
                referencedGroups.append(id)
                return .reference(id)
            }
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
            if let number = Int(name) {
                let id = number < 0 ? count + number + 1 : number
                referencedGroups.append(id)
                return .reference(id)
            }
            referencedNames.append(name)
            return .namedReference(name)
        default:
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
        var first = true
        while index < units.count && (units[index] != 93 || first) {
            first = false
            var node: RegexNode
            if index + 1 < units.count, units[index] == 91, units[index + 1] == 58 {
                index += 2
                let negative = take(94)
                let name = try readUntil(58)
                guard take(93) else {
                    throw diagnostic("POSIX 字符类未闭合")
                }
                node = .characterClass(try classKind(name, inverted: negative), false, [])
            }
            else if take(92) {
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
                    let endpoint: RegexNode
                    if take(92) {
                        endpoint = try escape(inClass: true)
                    }
                    else {
                        endpoint = .literal(units[index])
                        index += 1
                    }
                    guard case .literal(let b) = endpoint else {
                        throw diagnostic("字符范围端点必须是字面字符")
                    }
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

    /// 业务作用：把 Boost 的具名字符类归一为执行器中的独立分类，不接受不存在的 Unicode 类别别名。
    /// 参数说明:
    /// - name: 属性或 POSIX 字符类名称。
    /// - inverted: 是否对该分类取反。
    /// 返回：分类编码；未知名称失败而不扩大匹配范围。
    func classKind(_ name: String, inverted: Bool) throws -> String {
        let classes = [
            "alnum": "n", "alpha": "a", "blank": "t", "cntrl": "c", "d": "d", "digit": "d",
            "graph": "g", "h": "h", "l": "l", "lower": "l", "print": "p", "punct": "q",
            "s": "s", "space": "s", "u": "u", "unicode": "o", "upper": "u", "v": "v",
            "w": "w", "word": "w", "xdigit": "x",
        ]
        guard let kind = classes[name.lowercased()] else {
            throw diagnostic("未知字符类名称")
        }
        return inverted ? kind.uppercased() : kind
    }

}
