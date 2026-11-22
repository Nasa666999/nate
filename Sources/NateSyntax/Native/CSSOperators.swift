import Foundation
import NateCore

extension CSSScanner {
    /// 业务作用：普通 CSS 按操作符之前的真实类别区分选择器、属性、值与分组规则。
    /// 参数说明: 无。
    /// 返回：当前操作符上下文完整推进；缺少前置类别时拒绝猜测属性或选择器身份。
    mutating func operatorContext() throws {
        guard state.beforeOperator >= 0 else {
            throw NateError.message("CSS 操作符缺少完整前置类别。")
        }
        let before = UInt8(state.beforeOperator)
        let selector: [UInt8] = [0, 1, 2, 10, 3, 20, 4]
        switch state.op {
        case 64:
            if before == 0 {
                try setMode(12)
            }
        case 62, 43:
            if selector.contains(before), before != 0 {
                try setMode(0)
            }
        case 91:
            if selector.contains(before) {
                try setMode(16)
            }
        case 93:
            if before == 16 {
                try setMode(1)
            }
        case 123:
            if before == 22 {
                try setMode(0)
            }
            else if before == 1 || before == 12 {
                try setMode(6)
            }
        case 125:
            if [0, 8, 11, 6, 15, 17].contains(before) {
                try setMode(0)
            }
        case 40:
            if before == 3 {
                try setMode(1)
            }
            else if before == 20 {
                try setMode(20)
            }
        case 41:
            if selector.contains(before) || before == 18 || before == 21 {
                try setMode(1)
            }
        case 58:
            if selector.contains(before) || before == 18 || before == 21 {
                try setMode(3)
            }
            else if [6, 15, 17, 19, 7, 23].contains(before) {
                try setMode(8)
            }
        case 46:
            if selector.contains(before) {
                try setMode(2)
            }
        case 35:
            if selector.contains(before) {
                try setMode(10)
            }
        case 44, 124, 126:
            if before == 1 {
                try setMode(0)
            }
        case 59:
            if before == 12 {
                try setMode(0)
            }
            else if before == 8 || before == 11 {
                try setMode(state.insideParentheses ? before : 6)
            }
        case 33:
            if before == 8 {
                try setMode(11)
            }
        default:
            break
        }
    }
}
