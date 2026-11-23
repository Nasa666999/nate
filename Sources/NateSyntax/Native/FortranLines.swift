import Foundation
import NateCore

extension FortranScanner {
    /// 业务作用：固定格式的前五原字节、续行列和第七十三原字节之后按独立格式权限解释。
    /// 参数说明: 无。
    /// 返回：当前标量已由固定列分支处理时为真；失败不交付外部类别。
    mutating func fixedPrefix() throws -> Bool {
        let column = cursor - lineStart
        guard rules.fixedForm, column < 6 || column >= 72 else {
            return false
        }
        let value = try current()
        if column == 0 && [67, 99, 42].contains(value) || value == 33 {
            try setState(directive() ? 11 : 1)
            while !atLineEnd(), more() {
                try forward()
            }
        }
        else if column >= 72 {
            try setState(1)
            while !atLineEnd(), more() {
                try forward()
            }
        }
        else if column < 5 {
            try setState(FortranCharacters.digit(value) ? 13 : 0)
        }
        else if column == 5 {
            if value != 13, value != 10 {
                try setState(14)
                if !FortranCharacters.space(value), value != 48 {
                    try forwardState(state.previousStringMode)
                }
            }
            else {
                try setState(0)
            }
        }
        return true
    }

    /// 业务作用：自由格式的有限距离原字节前瞻先决定续行，再恢复此前类别；NUL 与 EOF 不可无限跳过。
    /// 参数说明: 无。
    /// 返回：真实续行及其空白和可选开端符按原生顺序分类；预算不足时拒绝。
    mutating func continuation() throws {
        guard !rules.fixedForm, try current() == 38, state.mode != 1 else {
            return
        }
        var look: UInt32 = 32
        var distance = 1
        while FortranCharacters.blank(look), distance < 132 {
            look = UInt32(try byte(at: cursor + distance))
            distance += 1
        }
        if look == 33 {
            try setState(14)
            if try next() == 33 {
                try forwardState(1)
            }
        }
        else if look == 13 || look == 10 {
            let previous = state.mode
            try setState(14)
            try forwardState(0)
            while try FortranCharacters.space(current()), more() {
                try forward()
                if atLineStart {
                    nonblank = 0
                }
                let value = try current()
                if value != 32, value != 9 {
                    nonblank += 1
                }
            }
            if try current() == 38 {
                try setState(14)
                try forward()
            }
            try setState(previous)
        }
    }
}
