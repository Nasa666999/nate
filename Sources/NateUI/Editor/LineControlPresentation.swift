import Foundation

enum LineControlPresentation {
    /// 业务作用：隐藏 ANSI 控制范围时保留全部原始 UTF-16 坐标，使命中、选区与候选仍对应正文。
    /// 参数说明:
    /// - text: 已完成控制字符占位的显示副本。
    /// - ranges: 当前显示副本中需要隐藏的完整原始控制范围。
    /// 返回：每个被隐藏单元改用零宽占位；无效范围保留完整原显示，不修改正文。
    static func hidingSequences(_ text: String, ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else {
            return text
        }
        var units = Array(text.utf16)
        // 不接受截断或溢出的坐标，避免隐藏错误的邻近正文或产生半个代理项。
        guard
            ranges.allSatisfy({
                $0.location >= 0 && $0.length >= 0 && $0.location <= units.count
                    && $0.length <= units.count - $0.location
                    && ($0.location == units.count || !(0xDC00...0xDFFF).contains(units[$0.location]))
                    && ($0.location + $0.length == units.count
                        || !(0xDC00...0xDFFF).contains(units[$0.location + $0.length]))
            })
        else {
            return text
        }
        for range in ranges {
            for index in range.location..<(range.location + range.length) {
                units[index] = 0x200B
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

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
