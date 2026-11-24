import Foundation

extension PieceTree {
    /// 业务作用：通过不可变子树证据确认等宽原生视口是否只包含独立可打印 ASCII，不展开超长逻辑行。
    /// 参数说明:
    /// - range: 同一正文上的完整 UTF-8 原字节范围。
    /// 返回：范围合法且每字节均为 U+0020 至 U+007E 时为真；Tab、控制、非 ASCII 或非法端点均为假。
    public func isPrintableASCII(in range: ByteRange) -> Bool {
        containsOnlyASCII(in: range, cached: \.printableASCII) {
            (32...126).contains($0)
        }
    }

    /// 业务作用：用共享正文的不可变证据确认长行只含 ASCII 字母与数字，可按实际原生字符断行投影视口。
    /// 参数说明:
    /// - range: 同一正文上的完整原字节范围。
    /// 返回：范围合法且全部为独立 ASCII 字母或数字时为真。
    public func isAlphanumericASCII(in range: ByteRange) -> Bool {
        containsOnlyASCII(in: range, cached: \.alphanumericASCII, includes: PieceNode.isASCIIAlphanumeric)
    }

    /// 业务作用：验证查询只访问真实标量之间的原字节范围。
    /// 参数说明:
    /// - range: 调用方提供的绝对原字节范围。
    /// - cached: 当前字符类别在共享节点中的完整证据。
    /// - includes: 部分覆盖时用于单字节复验的原字符类别。
    /// 返回：范围及全部包含字节属于该类别时为真。
    private func containsOnlyASCII(
        in range: ByteRange,
        cached: KeyPath<PieceNode, Bool>,
        includes: (UInt8) -> Bool
    ) -> Bool {
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= byteCount,
            isBoundary(range.lower), isBoundary(range.upper)
        else {
            return false
        }
        return Self.matchesASCII(
            root,
            lower: range.lower,
            upper: range.upper,
            cached: cached,
            includes: includes
        )
    }

    /// 业务作用：完整子树复用既有字符证据，仅在范围边缘扫描有界叶片，局部编辑不会触发全行重扫。
    /// 参数说明:
    /// - node: 当前不可变子树。
    /// - lower: 已验证的子树内起点。
    /// - upper: 已验证的子树内终点。
    /// - cached: 当前字符类别在共享节点中已经完整检查的结果。
    /// - includes: 部分覆盖时用于单字节复验的原字符类别。
    /// 返回：所有真实覆盖字节满足类别时为真，不读取无关正文。
    private static func matchesASCII(
        _ node: PieceNode,
        lower: Int,
        upper: Int,
        cached: KeyPath<PieceNode, Bool>,
        includes: (UInt8) -> Bool
    ) -> Bool {
        if lower == upper || node[keyPath: cached] {
            return true
        }
        if lower == 0 && upper == node.count {
            return false
        }
        if let left = node.left, let right = node.right {
            let before =
                lower >= left.count
                || matchesASCII(
                    left,
                    lower: lower,
                    upper: min(upper, left.count),
                    cached: cached,
                    includes: includes
                )
            guard before else {
                return false
            }
            return upper <= left.count
                || matchesASCII(
                    right,
                    lower: max(0, lower - left.count),
                    upper: upper - left.count,
                    cached: cached,
                    includes: includes
                )
        }
        return node.bytes[lower..<upper].allSatisfy(includes)
    }
}
