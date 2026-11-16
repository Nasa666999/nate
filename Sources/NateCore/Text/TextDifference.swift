import Foundation

public struct TextDifference: Sendable {
    public let originalRange: ByteRange
    public let replacementRange: ByteRange
}

extension PieceTree {
    /// 业务作用：重新载入只替换实际变化的连续范围，使追加日志和共同前后缀保留原位置关系。
    /// 参数说明:
    /// - target: 新读取的完整不可变正文。
    /// 返回：两个正文的最小连续差异边界，均为合法 UTF-8 范围；相同则为空。
    public func differenceBounds(to target: PieceTree) throws -> TextDifference? {
        if byteEqual(to: target) {
            return nil
        }
        let shared = min(byteCount, target.byteCount)
        var prefix = 0
        while prefix < shared {
            try Task.checkCancellation()
            let count = min(8192, shared - prefix)
            let original = bytes(in: ByteRange(prefix, prefix + count))
            let incoming = target.bytes(in: ByteRange(prefix, prefix + count))
            if let different = original.indices.first(where: {
                original[$0] != incoming[$0]
            }) {
                prefix += different
                break
            }
            prefix += count
        }
        // 相同字节前缀可能结束在多字节字符内部，替换范围必须包含该完整标量。
        while !isBoundary(prefix) || !target.isBoundary(prefix) {
            prefix -= 1
        }
        var suffix = 0
        let remaining = min(byteCount - prefix, target.byteCount - prefix)
        while suffix < remaining {
            try Task.checkCancellation()
            let count = min(8192, remaining - suffix)
            let original = bytes(in: ByteRange(byteCount - suffix - count, byteCount - suffix))
            let incoming = target.bytes(
                in: ByteRange(target.byteCount - suffix - count, target.byteCount - suffix)
            )
            if let different = original.indices.reversed().first(where: {
                original[$0] != incoming[$0]
            }) {
                suffix += count - different - 1
                break
            }
            suffix += count
        }
        while !isBoundary(byteCount - suffix) || !target.isBoundary(target.byteCount - suffix) {
            suffix -= 1
        }
        return TextDifference(
            originalRange: ByteRange(prefix, byteCount - suffix),
            replacementRange: ByteRange(prefix, target.byteCount - suffix)
        )
    }

    /// 业务作用：把连续差异转为普通编辑意图，显式需要替换正文时才复制该片段。
    /// 参数说明:
    /// - target: 目标正文。
    /// 返回：可直接提交的单项修改；相同正文返回空。
    public func difference(to target: PieceTree) throws -> TextEdit? {
        guard let difference = try differenceBounds(to: target) else {
            return nil
        }
        return TextEdit(difference.originalRange, target.text(in: difference.replacementRange))
    }
}
