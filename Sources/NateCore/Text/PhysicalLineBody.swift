extension PieceTree {
    /// 业务作用：按已确认的正文位置直接取得物理行的正文边界，密集列选择不反复统计叶片内的行号。
    /// 参数说明:
    /// - position: 当前正文范围内的原字节位置。
    /// 返回：排除 CR、LF 或 CRLF 的真实行范围；CRLF 内部仍归入前一行。
    func physicalLineBody(containing position: Int) -> ByteRange {
        guard root.breaks > 0 else {
            return ByteRange(0, byteCount)
        }
        var node = root
        var base = 0
        var offset = position
        var previous: (node: PieceNode, base: Int)?
        var following: (node: PieceNode, base: Int)?
        while let left = node.left, let right = node.right {
            let rightBase = base + left.count
            if offset < left.count {
                if right.breaks > 0 {
                    following = (right, rightBase)
                }
                node = left
            }
            else {
                if left.breaks > 0 {
                    previous = (left, base)
                }
                offset -= left.count
                base = rightBase
                node = right
            }
        }
        let bytes = node.bytes
        if offset < bytes.count, bytes[offset] == 10 {
            let before = offset > 0 ? bytes[offset - 1] : byte(at: position - 1)
            // 字节边界可能恰好落在跨叶片 CRLF 内，先找到同一原换行的真实开始位置。
            if before == 13 {
                return physicalLineBody(containing: position - 1)
            }
        }
        let lower =
            bytes[..<offset].lastIndex(where: Self.isPhysicalLineEnding).map {
                base + $0 + 1
            } ?? previous.flatMap {
                Self.nearestPhysicalLineEnding(in: $0.node, base: $0.base, forward: false).map {
                    $0 + 1
                }
            } ?? 0
        let upper =
            bytes[offset...].firstIndex(where: Self.isPhysicalLineEnding).map {
                base + $0
            } ?? following.flatMap {
                Self.nearestPhysicalLineEnding(in: $0.node, base: $0.base, forward: true)
            } ?? byteCount
        return ByteRange(lower, upper)
    }

    /// 业务作用：从已证明包含行尾字节的相邻子树获取最近一端，跳过不可能提供边缘的完整子树。
    /// 参数说明:
    /// - source: 至少含一个物理行尾字节的实际子树。
    /// - base: 该子树在原文中的字节起点。
    /// - forward: 为真时取最左行尾字节，为假时取最右。
    /// 返回：最近的实际行尾字节位置，未取得行尾证据时为空。
    private static func nearestPhysicalLineEnding(in source: PieceNode, base: Int, forward: Bool) -> Int? {
        var node = source
        var start = base
        while let left = node.left, let right = node.right {
            if forward ? left.breaks > 0 : right.breaks == 0 {
                node = left
            }
            else {
                start += left.count
                node = right
            }
        }
        let index =
            forward
            ? node.bytes.firstIndex(where: isPhysicalLineEnding)
            : node.bytes.lastIndex(where: isPhysicalLineEnding)
        return index.map {
            start + $0
        }
    }

    /// 业务作用：物理行按保存时实际的 CR、LF 字节划分，Unicode 显示断行不改变正文行。
    /// 参数说明:
    /// - byte: 原文中的一个字节。
    /// 返回：该字节可构成物理行结束符时为真。
    private static func isPhysicalLineEnding(_ byte: UInt8) -> Bool {
        byte == 13 || byte == 10
    }
}
