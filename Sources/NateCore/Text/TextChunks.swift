import Foundation

public struct TextChunk: Sendable {
    let tree: PieceTree
    public var id: UUID {
        tree.root.identity
    }
    public var byteCount: Int {
        tree.byteCount
    }
    public var utf16Count: Int {
        tree.utf16Count
    }

    /// 业务作用：为流式持久化提供有界原字节，分块身份不要求缓存保留整棵正文树。
    /// 参数说明: 无。
    /// 返回：本分块的合法 UTF-8 字节，最多为遍历时指定的分块上限。
    public func bytes() -> [UInt8] {
        tree.bytes()
    }
}

extension PieceTree {
    /// 业务作用：按共享子树遍历正文，局部修改不会移动所有后续分块边界或建立全文副本。
    /// 参数说明:
    /// - maximumBytes: 分块目标上限，限制在 4096 字节至 1 MB。
    /// - body: 顺序处理每个不可变分块，允许在分块边界停止。
    /// 返回：完整遍历时正文顺序保持不变；空文档没有分块。
    public func forEachChunk(maximumBytes: Int = 1_048_576, _ body: (TextChunk) throws -> Void) rethrows {
        let limit = max(4096, min(1_048_576, maximumBytes))
        try Self.visitChunks(root, maximumBytes: limit, body)
    }

    /// 业务作用：恢复流式读取的正文片段，不额外拼出整篇 String。
    /// 参数说明:
    /// - trees: 已校验 UTF-8 的连续正文片段。
    /// 返回：完整的平衡正文树，原标量、跨块 CRLF 与组合字符保持原序。
    public static func joining(_ trees: [PieceTree]) -> PieceTree {
        var nodes = trees.map(\.root).filter {
            $0.count > 0
        }
        guard !nodes.isEmpty else {
            return PieceTree()
        }
        while nodes.count > 1 {
            var next: [PieceNode] = []
            for index in stride(from: 0, to: nodes.count, by: 2) {
                if index + 1 < nodes.count {
                    next.append(join(nodes[index], nodes[index + 1]))
                }
                else {
                    next.append(nodes[index])
                }
            }
            nodes = next
        }
        return PieceTree(root: nodes[0])
    }

    /// 业务作用：尽量复用完整子树作为恢复分块，分块仅在大小超限时继续细分。
    /// 参数说明:
    /// - node: 当前不可变子树。
    /// - maximumBytes: 本次单块字节上限。
    /// - body: 按正文顺序调用的处理入口。
    /// 返回：所有非空字节恰好访问一次，不复制未请求的全文。
    private static func visitChunks(_ node: PieceNode, maximumBytes: Int, _ body: (TextChunk) throws -> Void)
        rethrows
    {
        guard node.count > 0 else {
            return
        }
        if node.count <= maximumBytes {
            try body(TextChunk(tree: PieceTree(root: node)))
        }
        else if let left = node.left, let right = node.right {
            try visitChunks(left, maximumBytes: maximumBytes, body)
            try visitChunks(right, maximumBytes: maximumBytes, body)
        }
    }
}
