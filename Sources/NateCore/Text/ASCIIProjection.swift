import Foundation

extension PieceTree {
    /// 业务作用：通过不可变子树证据确认等宽原生视口是否只包含独立可打印 ASCII，不展开超长逻辑行。
    /// 参数说明:
    /// - range: 同一正文上的完整 UTF-8 原字节范围。
    /// 返回：范围合法且每字节均为 U+0020 至 U+007E 时为真；Tab、控制、非 ASCII 或非法端点均为假。
    public func isPrintableASCII(in range: ByteRange) -> Bool {
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= byteCount,
            isBoundary(range.lower), isBoundary(range.upper)
        else {
            return false
        }
        return Self.printableASCII(root, lower: range.lower, upper: range.upper)
    }

    /// 业务作用：完整子树复用既有字符证据，仅在范围边缘扫描有界叶片，局部编辑不会触发全行重扫。
    /// 参数说明:
    /// - node: 当前不可变子树。
    /// - lower: 已验证的子树内起点。
    /// - upper: 已验证的子树内终点。
    /// 返回：所有实际覆盖字节均满足可打印 ASCII 时为真，不读取无关正文。
    private static func printableASCII(_ node: PieceNode, lower: Int, upper: Int) -> Bool {
        if lower == upper || node.printableASCII {
            return true
        }
        if lower == 0 && upper == node.count {
            return false
        }
        if let left = node.left, let right = node.right {
            let before =
                lower >= left.count || printableASCII(left, lower: lower, upper: min(upper, left.count))
            guard before else {
                return false
            }
            return upper <= left.count
                || printableASCII(right, lower: max(0, lower - left.count), upper: upper - left.count)
        }
        return node.bytes[lower..<upper].allSatisfy {
            (32...126).contains($0)
        }
    }
}
