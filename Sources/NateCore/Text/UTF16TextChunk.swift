import Foundation

public struct UTF16TextChunk: Sendable {
    public let start: Int
    public let units: [UInt16]
}

extension PieceTree {
    /// 业务作用：按树索引读取包含指定 UTF-16 单元的完整叶片，不为局部查找建立全文投影。
    /// 参数说明:
    /// - position: 从零开始的 UTF-16 单元索引，允许指向代理项的任意一半。
    /// 返回：全局起点及至多 4096 个 UTF-16 单元；越界或空正文返回空值，原始标量和 CRLF 不归一化。
    public func utf16Chunk(containing position: Int) -> UTF16TextChunk? {
        guard position >= 0, position < utf16Count else {
            return nil
        }
        var node = root
        var remaining = position
        var start = 0
        while let left = node.left, let right = node.right {
            if remaining < left.utf16Count {
                node = left
            }
            else {
                remaining -= left.utf16Count
                start += left.utf16Count
                node = right
            }
        }
        // 叶片按合法 UTF-8 标量构建；保留原始 UTF-16 单元才能兼容字符类、反向引用和半代理项命中。
        return UTF16TextChunk(
            start: start,
            units: Array(String(decoding: node.bytes, as: UTF8.self).utf16)
        )
    }
}
