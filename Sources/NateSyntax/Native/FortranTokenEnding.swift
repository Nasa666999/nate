import Foundation
import NateCore

extension FortranScanner {
    /// 业务作用：名称、数字和字面的收束先于新类别进入，错误行尾不重写此前已交付的状态片段。
    /// 参数说明: 无。
    /// 返回：当前待定类别按真实标量、物理行尾与 EOF 完整收束；预算不足时拒绝。
    mutating func finishToken() throws {
        let value = try current()
        switch state.mode {
        case 6:
            try setState(0)
        case 2:
            if !FortranCharacters.word(value), ![39, 34, 46].contains(value) {
                try setState(0)
            }
        case 7:
            if !FortranCharacters.word(value) || value == 37 {
                guard emitted <= cursor, emitted <= bytes.count else {
                    throw NateError.invalidRange
                }
                let end = min(cursor, emitted + 99)
                let candidate = Data(bytes[emitted..<end].prefix { $0 != 0 }.map(FortranCharacters.folded))
                for group in 0..<3 {
                    if try rules.contains(candidate, group: group, budget: &budget) {
                        state.mode = UInt8(8 + group)
                        break
                    }
                }
                try setState(0)
            }
        case 1, 11:
            if value == 13 || value == 10 {
                try setState(0)
            }
        case 3:
            state.previousStringMode = 3
            if value == 39 {
                if try next() == 39 {
                    try forward()
                }
                else {
                    try forwardState(0)
                    state.previousStringMode = 0
                }
            }
            else if atLineEnd() {
                state.mode = 5
                try forwardState(0)
            }
        case 4:
            state.previousStringMode = 4
            if atLineEnd() {
                state.mode = 5
                try forwardState(0)
            }
            else if value == 34 {
                if try next() == 34 {
                    try forward()
                }
                else {
                    try forwardState(0)
                    state.previousStringMode = 0
                }
            }
        case 12:
            if value == 46 {
                try forwardState(0)
            }
        case 14:
            try setState(0)
        case 13:
            if !FortranCharacters.digit(value) || rules.fixedForm && cursor - lineStart > 4 || nonblank > 5 {
                try setState(0)
            }
        default:
            break
        }
    }
}
