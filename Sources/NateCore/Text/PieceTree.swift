import Foundation

/// 不可变节点允许快照和历史共享正文；仅修改路径上的节点需要重新建立。
final class PieceNode: Sendable {
    let identity = UUID()
    let left: PieceNode?
    let right: PieceNode?
    let bytes: [UInt8]
    let count: Int
    let utf16Count: Int
    let breaks: Int
    let height: Int
    let first: UInt8?
    let last: UInt8?
    let contentFingerprint: UInt64
    let fingerprintPower: UInt64
    let printableASCII: Bool

    /// 业务作用：缓存叶片的坐标与行索引，限制每次局部扫描的规模。
    /// 参数说明:
    /// - bytes: 合法 UTF-8 且不在内部拆分 CRLF 的片段。
    /// 返回：不可变叶片，可跨后台任务共享。
    init(bytes: [UInt8]) {
        self.bytes = bytes
        left = nil
        right = nil
        count = bytes.count
        utf16Count = String(decoding: bytes, as: UTF8.self).utf16.count
        breaks = Self.countBreaks(bytes)
        height = 1
        first = bytes.first
        last = bytes.last
        var fingerprint: UInt64 = 0
        var power: UInt64 = 1
        var printableASCII = true
        for byte in bytes {
            fingerprint = fingerprint &* 1_099_511_628_211 &+ UInt64(byte) &+ 1
            power = power &* 1_099_511_628_211
            if byte < 32 || byte > 126 {
                printableASCII = false
            }
        }
        contentFingerprint = fingerprint
        fingerprintPower = power
        self.printableASCII = printableASCII
    }

    /// 业务作用：聚合子树索引，跨节点 CRLF 只计一行。
    /// 参数说明:
    /// - left: 前段正文。
    /// - right: 后段正文。
    /// 返回：结构共享的父节点。
    init(left: PieceNode, right: PieceNode) {
        self.left = left
        self.right = right
        bytes = []
        count = left.count + right.count
        utf16Count = left.utf16Count + right.utf16Count
        breaks = left.breaks + right.breaks - (left.last == 13 && right.first == 10 ? 1 : 0)
        height = max(left.height, right.height) + 1
        first = left.first ?? right.first
        last = right.last ?? left.last
        contentFingerprint = left.contentFingerprint &* right.fingerprintPower &+ right.contentFingerprint
        fingerprintPower = left.fingerprintPower &* right.fingerprintPower
        printableASCII = left.printableASCII && right.printableASCII
    }

    /// 业务作用：以文件真实换行统计逻辑行，CRLF 不重复计算。
    /// 参数说明:
    /// - bytes: 叶片原始字节。
    /// 返回：LF、CR 与 CRLF 的总换行数。
    static func countBreaks(_ bytes: [UInt8]) -> Int {
        var result = 0
        var previous: UInt8 = 0
        for value in bytes {
            if value == 13 || (value == 10 && previous != 13) {
                result += 1
            }
            previous = value
        }
        return result
    }
}

public struct PieceTree: Sendable {
    let root: PieceNode
    public var byteCount: Int {
        root.count
    }
    public var utf16Count: Int {
        root.utf16Count
    }
    public var lineCount: Int {
        root.breaks + 1
    }

    /// 业务作用：将初始正文分块，避免后续输入复制整篇文本。
    /// 参数说明:
    /// - text: 保留原始 Unicode 标量与混合换行的正文。
    /// 返回：可廉价复制的不可变正文快照。
    public init(_ text: String = "") {
        let bytes = Array(text.utf8)
        var nodes: [PieceNode] = []
        var start = 0
        while start < bytes.count {
            var end = min(start + 4096, bytes.count)
            while end < bytes.count && (bytes[end] & 0xC0) == 0x80 {
                end -= 1
            }
            if end < bytes.count && end > start && bytes[end - 1] == 13 && bytes[end] == 10 {
                end -= 1
            }
            nodes.append(PieceNode(bytes: Array(bytes[start..<end])))
            start = end
        }
        if nodes.isEmpty {
            nodes = [PieceNode(bytes: [])]
        }
        while nodes.count > 1 {
            var level: [PieceNode] = []
            for i in stride(from: 0, to: nodes.count, by: 2) {
                level.append(i + 1 < nodes.count ? PieceNode(left: nodes[i], right: nodes[i + 1]) : nodes[i])
            }
            nodes = level
        }
        root = nodes[0]
    }

    /// 业务作用：包装已完成结构共享的根节点。
    /// 参数说明:
    /// - root: 新快照的不可变根。
    /// 返回：正文快照，不产生复制。
    init(root: PieceNode) {
        self.root = root
    }

    /// 业务作用：只提取指定快照范围，供行排版、编码与搜索读取。
    /// 参数说明:
    /// - range: 有界 UTF-8 范围；省略时读取全文。
    /// 返回：原字节序列，不执行 Unicode 归一化。
    public func bytes(in range: ByteRange? = nil) -> [UInt8] {
        let range = range ?? ByteRange(0, byteCount)
        guard range.lower >= 0, range.upper <= byteCount, range.lower <= range.upper else {
            return []
        }
        var result: [UInt8] = []
        result.reserveCapacity(range.count)
        Self.collect(root, offset: 0, range: range, into: &result)
        return result
    }

    /// 业务作用：向文本服务提供指定范围的只读文字。
    /// 参数说明:
    /// - range: 已验证的 UTF-8 范围。
    /// 返回：正文副本，仅在显式读取范围时建立。
    public func text(in range: ByteRange? = nil) -> String {
        String(decoding: bytes(in: range), as: UTF8.self)
    }

    /// 业务作用：阻止系统坐标切开 UTF-8 多字节序列。
    /// 参数说明:
    /// - offset: 待校验的字节位置。
    /// 返回：仅合法标量边界为真。
    public func isBoundary(_ offset: Int) -> Bool {
        guard offset >= 0 && offset <= byteCount else {
            return false
        }
        return offset == byteCount
            || byte(at: offset).map {
                ($0 & 0xC0) != 0x80
            } == true
    }

    /// 业务作用：通过树索引访问单字节，不展开全文。
    /// 参数说明:
    /// - offset: 文档内字节位置。
    /// 返回：越界时为空。
    public func byte(at offset: Int) -> UInt8? {
        guard offset >= 0 && offset < byteCount else {
            return nil
        }
        var node = root
        var index = offset
        while let left = node.left, let right = node.right {
            if index < left.count {
                node = left
            }
            else {
                index -= left.count
                node = right
            }
        }
        return node.bytes[index]
    }

    /// 业务作用：在编辑前快照上替换一段正文，保留未修改子树。
    /// 参数说明:
    /// - range: 被替换的合法标量范围。
    /// - text: 要插入的合法文本。
    /// 返回：新正文；非法范围不改变旧快照。
    public func replacing(_ range: ByteRange, with text: String) throws -> PieceTree {
        guard range.lower <= range.upper, isBoundary(range.lower), isBoundary(range.upper) else {
            throw NateError.invalidRange
        }
        let (before, tail) = Self.split(root, at: range.lower)
        let (_, after) = Self.split(tail, at: range.count)
        return PieceTree(root: Self.join(Self.join(before, PieceTree(text).root), after))
    }

    /// 业务作用：从原快照结构共享取得完整范围，行重排与校验不为每段正文建立完整中间字符串。
    /// 参数说明:
    /// - range: 原快照中的完整 UTF-8 标量范围。
    /// 返回：只切分边界叶片的新树；非法范围拒绝，原快照保持不变。
    public func slicing(_ range: ByteRange) throws -> PieceTree {
        guard range.lower <= range.upper, isBoundary(range.lower), isBoundary(range.upper) else {
            throw NateError.invalidRange
        }
        let (_, tail) = Self.split(root, at: range.lower)
        let (selected, _) = Self.split(tail, at: range.count)
        return PieceTree(root: selected)
    }

    /// 业务作用：大段重排逐块验证真实字节，摘要相同不能代替完整复验，取消可在读取边界停止。
    /// 参数说明:
    /// - other: 需要比较的不可变正文片段。
    /// - permit: 当前仍有时间和权限继续验证的资格。
    /// 返回：全部字节相同时为真，不同则为假；取消或失权不返回未经完成的相等结论。
    public func byteEqual(to other: PieceTree, permit: @Sendable () -> Bool) throws -> Bool {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        if root === other.root {
            return true
        }
        guard byteCount == other.byteCount, root.contentFingerprint == other.root.contentFingerprint else {
            return false
        }
        for start in stride(from: 0, to: byteCount, by: 8192) {
            try Task.checkCancellation()
            guard permit() else {
                throw CancellationError()
            }
            let range = ByteRange(start, min(byteCount, start + 8192))
            guard bytes(in: range) == other.bytes(in: range) else {
                return false
            }
        }
        return true
    }

    /// 业务作用：准确判断磁盘保存点，避免 Swift 规范等价比较掩盖字节变化。
    /// 参数说明:
    /// - other: 要比较的已持久化快照。
    /// 返回：长度与每个字节相等，或共享同一根时为真。
    public func byteEqual(to other: PieceTree) -> Bool {
        if root === other.root {
            return true
        }
        // 不同指纹可立即证明有变化；相同指纹仍逐字节复验，碰撞不能清除待保存状态。
        guard byteCount == other.byteCount, root.contentFingerprint == other.root.contentFingerprint else {
            return false
        }
        for start in stride(from: 0, to: byteCount, by: 8192) {
            let range = ByteRange(start, min(start + 8192, byteCount))
            if bytes(in: range) != other.bytes(in: range) {
                return false
            }
        }
        return true
    }

    /// 业务作用：只访问与读取范围相交的叶片。
    /// 参数说明:
    /// - node: 当前子树。
    /// - offset: 子树在全文中的起点。
    /// - range: 读取范围。
    /// - result: 汇集的原字节。
    /// 返回：向目标追加范围内字节。
    private static func collect(_ node: PieceNode, offset: Int, range: ByteRange, into result: inout [UInt8])
    {
        guard offset < range.upper, offset + node.count > range.lower else {
            return
        }
        if let left = node.left, let right = node.right {
            collect(left, offset: offset, range: range, into: &result)
            collect(right, offset: offset + left.count, range: range, into: &result)
        }
        else {
            result.append(
                contentsOf: node.bytes[max(0, range.lower - offset)..<min(node.count, range.upper - offset)]
            )
        }
    }

    /// 业务作用：通过路径复制拆分正文，历史仍持有原节点。
    /// 参数说明:
    /// - node: 待拆分子树。
    /// - at: 子树内合法字节边界。
    /// 返回：前后两棵不可变子树。
    private static func split(_ node: PieceNode, at: Int) -> (PieceNode, PieceNode) {
        if at <= 0 {
            return (PieceNode(bytes: []), node)
        }
        if at >= node.count {
            return (node, PieceNode(bytes: []))
        }
        guard let left = node.left, let right = node.right else {
            return (PieceNode(bytes: Array(node.bytes[..<at])), PieceNode(bytes: Array(node.bytes[at...])))
        }
        if at < left.count {
            let (a, b) = split(left, at: at)
            return (a, join(b, right))
        }
        let (a, b) = split(right, at: at - left.count)
        return (join(left, a), b)
    }

    /// 业务作用：维持树高平衡，使局部输入和坐标查询不退化为线性遍历。
    /// 参数说明:
    /// - left: 前段子树。
    /// - right: 后段子树。
    /// 返回：保持正文顺序的平衡树。
    static func join(_ left: PieceNode, _ right: PieceNode) -> PieceNode {
        if left.count == 0 {
            return right
        }
        if right.count == 0 {
            return left
        }
        if left.height > right.height + 1, let a = left.left, let b = left.right {
            if a.height >= b.height {
                return PieceNode(left: a, right: join(b, right))
            }
            if let c = b.left, let d = b.right {
                return PieceNode(left: join(a, c), right: join(d, right))
            }
        }
        if right.height > left.height + 1, let a = right.left, let b = right.right {
            if b.height >= a.height {
                return PieceNode(left: join(left, a), right: b)
            }
            if let c = a.left, let d = a.right {
                return PieceNode(left: join(left, c), right: join(d, b))
            }
        }
        return PieceNode(left: left, right: right)
    }
}
