import Foundation
import NateCore

extension TOMLScanner {
    /// 业务作用：TOML 新词按注释、行首键或表头和值的原生优先顺序取得类别。
    /// 参数说明: 无。
    /// 返回：当前原生类别与键、容器及行元数据同步设置；容器超量时拒绝。
    mutating func beginToken() throws {
        if current == 35 {
            try setMode(1)
            if state.visibleChars == 0 {
                state.lineType = 2
            }
        }
        else if state.visibleChars == 0, state.braceCount == 0 {
            if current == 91 {
                state.tableLevel = 0
                try setMode(5)
                if try next() == 91 {
                    try advance()
                }
                state.keyState = 0
                state.lineType = 1
            }
            else if current == 39 || current == 34 {
                state.keyState = current == 39 ? 1 : 2
                try setMode(6)
            }
            else if Self.unquoted(current) {
                state.keyState = 0
                try setMode(6)
            }
            else if !Self.space(current) {
                try setMode(7)
            }
        }
        else {
            if current == 39 || current == 34 {
                let double = current == 34
                if try tripleQuote() {
                    try setMode(double ? 12 : 11)
                    try advance()
                    try advance()
                }
                else {
                    try setMode(double ? 10 : 9)
                }
            }
            else if current >= 48 && current <= 57 {
                try setMode(4)
            }
            else if current >= 97 && current <= 122 {
                try setMode(2)
            }
            else if [91, 93, 123, 125, 44, 61, 46, 43, 45].contains(current) {
                try setMode(8)
                if current == 91 || current == 123 {
                    guard state.braceCount < 65_536 else {
                        throw NateError.message("TOML 容器层级超过完整容量。")
                    }
                    state.braceCount += 1
                }
                else if current == 93 || current == 125 {
                    state.braceCount = max(0, state.braceCount - 1)
                }
            }
            else if state.braceCount > 0, Self.unquoted(current) {
                state.keyState = 0
                try setMode(6)
            }
        }
    }
}
