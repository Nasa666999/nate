import Foundation

enum LineControlPresentation {
    /// 业务作用：逻辑行中的控制字符以可见占位呈现，避免 TextKit 把它们当作终止符而隐藏后续正文。
    /// 参数说明:
    /// - text: 当前逻辑行的原始正文，不含行结束符。
    /// 返回：UTF-16 长度与原文完全相同的排版文字，Tab 和普通 Unicode 保持原样，不写入正文或剪贴板。
    static func render(_ text: String) -> String {
        guard
            text.unicodeScalars.contains(where: {
                replacement(for: $0.value) != nil
            })
        else {
            return text
        }
        var output = String.UnicodeScalarView()
        output.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars {
            // 占位必须仍占一个 UTF-16 单元，多字符标签会让语法、选区和输入法坐标脱离原正文。
            output.append(replacement(for: scalar.value) ?? scalar)
        }
        return String(output)
    }

    /// 业务作用：仅替换会隐藏内容或触发原生断段的单单元控制字符，保持内核逻辑行与显示行的一致性。
    /// 参数说明:
    /// - value: 原始 Unicode 标量值。
    /// 返回：控制字符对应的可见单单元符号；Tab、方向控制和普通文字不替换。
    private static func replacement(for value: UInt32) -> Unicode.Scalar? {
        switch value {
        case 0...8, 10...31: return Unicode.Scalar(0x2400 + value)
        case 127: return Unicode.Scalar(0x2421)
        case 0x85: return Unicode.Scalar(0x2424)
        case 0x2028: return Unicode.Scalar(0x21B5)
        case 0x2029: return Unicode.Scalar(0x00B6)
        default: return nil
        }
    }
}
