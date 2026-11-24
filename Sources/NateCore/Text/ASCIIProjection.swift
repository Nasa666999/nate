import Foundation

extension PieceTree {
    /// 业务作用：通过不可变子树证据确认等宽原生视口是否只包含独立可打印 ASCII，不展开超长逻辑行。
    /// 参数说明:
    /// - range: 同一正文上的完整 UTF-8 原字节范围。
    /// 返回：范围合法且每字节均为 U+0020 至 U+007E 时为真；Tab、控制、非 ASCII 或非法端点均为假。
    public func isPrintableASCII(in range: ByteRange) -> Bool {
        containsOnly(in: range, cached: \.printableASCII) { bytes in
            bytes.allSatisfy { (32...126).contains($0) }
        }
    }

    /// 业务作用：用共享正文的不可变证据确认长行只含 ASCII 字母与数字，可按实际原生字符断行投影视口。
    /// 参数说明:
    /// - range: 同一正文上的完整原字节范围。
    /// 返回：范围合法且全部为独立 ASCII 字母或数字时为真。
    public func isAlphanumericASCII(in range: ByteRange) -> Bool {
        containsOnly(in: range, cached: \.alphanumericASCII) { bytes in
            bytes.allSatisfy(PieceNode.isASCIIAlphanumeric)
        }
    }

    /// 业务作用：纯基本统一汉字的有界窗口可用已确认子树取得完整固定字节宽度。
    /// 参数说明:
    /// - range: 同一正文上落在完整 UTF-8 标量边缘的范围。
    /// 返回：所有原标量属于 U+4E00 至 U+9FFF 时为真。
    func containsOnlyUnifiedIdeographs(in range: ByteRange) -> Bool {
        containsOnly(in: range, cached: \.unifiedIdeographs, leafMatches: PieceNode.onlyUnifiedIdeographs)
    }

    /// 业务作用：验证查询只访问真实标量之间的原字节范围。
    /// 参数说明:
    /// - range: 调用方提供的绝对原字节范围。
    /// - cached: 当前字符类别在共享节点中的完整证据。
    /// - leafMatches: 部分覆盖时用于复验原标量类别的有界叶片查询。
    /// 返回：范围及全部包含标量属于该类别时为真。
    private func containsOnly(
        in range: ByteRange,
        cached: KeyPath<PieceNode, Bool>,
        leafMatches: (ArraySlice<UInt8>) -> Bool
    ) -> Bool {
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= byteCount,
            isBoundary(range.lower), isBoundary(range.upper)
        else {
            return false
        }
        return Self.matches(
            root,
            lower: range.lower,
            upper: range.upper,
            cached: cached,
            leafMatches: leafMatches
        )
    }

    /// 业务作用：完整子树复用既有字符证据，仅在范围边缘扫描有界叶片，局部编辑不会触发全行重扫。
    /// 参数说明:
    /// - node: 当前不可变子树。
    /// - lower: 已验证的子树内起点。
    /// - upper: 已验证的子树内终点。
    /// - cached: 当前字符类别在共享节点中已经完整检查的结果。
    /// - leafMatches: 部分覆盖时用于复验原标量类别的有界叶片查询。
    /// 返回：所有实际覆盖的原标量满足类别时为真，不读取无关正文。
    private static func matches(
        _ node: PieceNode,
        lower: Int,
        upper: Int,
        cached: KeyPath<PieceNode, Bool>,
        leafMatches: (ArraySlice<UInt8>) -> Bool
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
                || matches(
                    left,
                    lower: lower,
                    upper: min(upper, left.count),
                    cached: cached,
                    leafMatches: leafMatches
                )
            guard before else {
                return false
            }
            return upper <= left.count
                || matches(
                    right,
                    lower: max(0, lower - left.count),
                    upper: upper - left.count,
                    cached: cached,
                    leafMatches: leafMatches
                )
        }
        return leafMatches(node.bytes[lower..<upper])
    }
}
