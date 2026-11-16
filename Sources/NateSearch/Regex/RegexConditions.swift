import Foundation
import NateCore

indirect enum RegexCondition: Sendable {
    case capture(Int)
    case named(String)
    case assertion(RegexNode)
    case definition
}

extension RegexParser {
    /// 业务作用：解析条件分支的捕获或断言门禁，定义块只登记子程序而不消费正文。
    /// 参数说明:
    /// - depth: 条件所在的语法深度。
    /// 返回：已经消费条件右括号的门禁；非法条件失败。
    mutating func conditionalTest(depth: Int) throws -> RegexCondition {
        let condition: RegexCondition
        if let id = number() {
            referencedGroups.append(id)
            condition = .capture(id)
        }
        else if take(60) || take(39) {
            let end: UInt16 = units[index - 1] == 60 ? 62 : 39
            let name = try readUntil(end)
            referencedNames.append(name)
            condition = .named(name)
        }
        else if take(63) {
            let behind = take(60)
            let positive: Bool
            if take(61) {
                positive = true
            }
            else if take(33) {
                positive = false
            }
            else {
                throw diagnostic("条件断言缺少方向")
            }
            let expression = try expression(depth: depth)
            let width = behind ? fixedWidth(expression) : nil
            guard !behind || width != nil else {
                throw diagnostic("条件 Lookbehind 必须使用固定长度")
            }
            condition = .assertion(.assertion(expression, positive, width))
        }
        else {
            let name = try readUntil(41)
            guard name == "DEFINE" else {
                throw diagnostic("条件名称必须使用名称界定符")
            }
            return .definition
        }
        guard take(41) else {
            throw diagnostic("条件表达式未闭合")
        }
        return condition
    }
}
