import Foundation
import NateCore

extension FortranScanner {
    /// 业务作用：新类别按注释、标签、数字与 BOZ、点操作符、名称和引号的原生优先级进入。
    /// 参数说明: 无。
    /// 返回：当前完整标量取得明确类别；边界或预算不足时拒绝部分分类。
    mutating func enterToken() throws {
        let value = try current()
        if value == 33 {
            try setState(directive() ? 11 : 1)
        }
        else if !rules.fixedForm, FortranCharacters.digit(value), nonblank == 1 {
            try setState(13)
        }
        else if try FortranCharacters.digit(value) || value == 46 && FortranCharacters.digit(next()) {
            try setState(2)
        }
        else if [66, 98, 79, 111, 90, 122].contains(value), try [34, 39].contains(next()) {
            try setState(2)
            try forward()
        }
        else if value == 46, try FortranCharacters.alpha(next()) {
            try setState(12)
        }
        else if FortranCharacters.alphanumeric(value) {
            try setState(7)
        }
        else if value == 34 {
            try setState(4)
        }
        else if value == 39 {
            try setState(3)
        }
        else if FortranCharacters.operation(value) {
            try setState(6)
        }
    }

    /// 业务作用：编译器指令注释只匹配原生有限前缀，不把普通感叹号注释授予预处理身份。
    /// 参数说明: 无。
    /// 返回：当前原文包含明确指令前缀或紧邻美元标记时为真；预算不足时拒绝。
    mutating func directive() throws -> Bool {
        for prefix in ["cdec$", "*dec$", "!dec$", "cdir$", "*dir$", "!dir$", "cms$", "*ms$", "!ms$", "!gcc$"]
        {
            var matches = true
            for (offset, expected) in prefix.utf8.enumerated() {
                if try FortranCharacters.folded(byte(at: cursor + offset)) != expected {
                    matches = false
                    break
                }
            }
            if matches {
                return true
            }
        }
        return try next() == 36
    }
}
