import Foundation
import NateCore

extension RegexParser {
    /// 业务作用：解析捕获、断言、子程序和回溯控制，未知动词在匹配前失败，组内模式不泄漏到外层。
    /// 参数说明:
    /// - depth: 外层语法深度。
    /// 返回：完整分组节点；结构或捕获引用无效时失败。
    mutating func group(depth: Int) throws -> RegexNode {
        if take(42) {
            let name = try readUntil(41)
            guard let verb = RegexVerb(rawValue: name == "F" ? "FAIL" : name) else {
                throw diagnostic("未知回溯控制动词或不支持的动词参数")
            }
            return .control(verb)
        }
        var group: Int?
        var assertion: (Bool, Bool)?
        var atomic = false
        if take(63) {
            if take(58) {
            }
            else if take(124) {
                let inside = try expression(depth: depth + 1, resettingCaptures: true)
                guard take(41) else {
                    throw diagnostic("分支重置组未闭合")
                }
                return inside
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
            else if take(40) {
                let condition = try conditionalTest(depth: depth + 1)
                let branches = try expression(depth: depth + 1)
                guard take(41) else {
                    throw diagnostic("条件分组未闭合")
                }
                if case .alternate(let alternatives) = branches {
                    guard alternatives.count == 2 else {
                        throw diagnostic("条件表达式只能有两个分支")
                    }
                    return .conditional(condition, alternatives[0], alternatives[1])
                }
                return .conditional(condition, branches, .empty)
            }
            else if take(38) {
                let name = try readUntil(41)
                referencedNames.append(name)
                return .namedRecurse(name)
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
                    names[name, default: []].append(count)
                }
            }
            else if take(39) {
                let name = try readUntil(39)
                count += 1
                group = count
                names[name, default: []].append(count)
            }
            else if take(82) || take(48) {
                guard take(41) else {
                    throw diagnostic("递归调用缺少右括号")
                }
                return .recurse(0)
            }
            else if index + 1 < units.count, [43, 45].contains(units[index]),
                (48...57).contains(units[index + 1])
            {
                let forward = take(43)
                if !forward {
                    index += 1
                }
                guard let distance = number(), distance > 0, take(41) else {
                    throw diagnostic("相对子程序编号无效或缺少右括号")
                }
                let sum = count.addingReportingOverflow(forward ? distance : -distance + 1)
                guard !sum.overflow, sum.partialValue > 0 else {
                    throw diagnostic("相对子程序编号超出捕获范围")
                }
                referencedGroups.append(sum.partialValue)
                return .recurse(sum.partialValue)
            }
            else if let number = number() {
                guard take(41) else {
                    throw diagnostic("子程序调用缺少右括号")
                }
                referencedGroups.append(number)
                return .recurse(number)
            }
            else {
                let outerModes = modes
                var enabled = true
                while index < units.count && units[index] != 58 && units[index] != 41 {
                    try checkpoint()
                    let flag = units[index]
                    index += 1
                    if flag == 45 {
                        enabled = false
                    }
                    else if flag == 105 {
                        modes.sensitive = !enabled
                    }
                    else if flag == 115 {
                        modes.dot = enabled
                    }
                    else if flag == 109 {
                        modes.multiline = enabled
                    }
                    else if flag == 120 {
                        modes.extended = enabled
                    }
                    else {
                        throw diagnostic("无法识别的模式开关")
                    }
                }
                if take(41) {
                    return .directive
                }
                guard take(58) else {
                    throw diagnostic("模式组缺少冒号")
                }
                let inside = try expression(depth: depth + 1)
                modes = outerModes
                guard take(41) else {
                    throw diagnostic("模式组未闭合")
                }
                return inside
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
            guard !assertion.1 || allowsLookbehind else {
                throw diagnostic("函数列表规则不支持后行断言")
            }
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
            // 重置分支可以复用捕获编号；子程序始终指向该编号的首个定义，而实际捕获由当前匹配路径确认。
            if groups[group] == nil {
                groups[group] = inside
            }
            return .capture(group, inside)
        }
        return inside
    }
}
