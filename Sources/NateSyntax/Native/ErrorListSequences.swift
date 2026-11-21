import Foundation

extension ANSILexing {
    /// 业务作用：诊断日志使用自己的十六色序列规则，不沿用 ANSI 文件模式的背景与取消粗体语义。
    /// 参数说明:
    /// - start: 当前 CSI 参数起点。
    /// - end: 终止命令之前的原始边界。
    /// 返回：ErrorList 的固定样式编号；只改变呈现，不执行外部终端动作。
    mutating func diagnosticSequenceStyle(_ start: Int, _ end: Int) throws -> Int {
        var style = 0
        var bold = false
        var cursor = start
        while cursor < end {
            try budget.consume()
            if bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                var value = Int(bytes[cursor] - 48)
                cursor += 1
                if cursor < end, bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                    try budget.consume()
                    value = value * 10 + Int(bytes[cursor] - 48)
                    cursor += 1
                }
                switch value {
                case 0:
                    style = 0
                    bold = false
                case 1:
                    bold = true
                    if style == 0 {
                        style = 40
                    }
                case 30...37:
                    style = value + 10
                case 90...97:
                    style = value - 42
                default:
                    break
                }
            }
            else {
                cursor += 1
            }
        }
        return bold && style >= 40 && style <= 47 ? style + 8 : style
    }
}
