import NateCore

// 每轮同步执行独占可变缓存；可跨任务共享的 PreparedSearchInput 只保存不可变正文证据。
final class SearchInput {
    let count: Int
    private let text: PieceTree
    private var chunks: [UTF16TextChunk] = []
    private var current: [UInt16] = []
    private var start = 0
    private var end = 0

    /// 业务作用：绑定固定正文并延迟读取 UTF-16 叶片，查询开始时不复制整篇文本。
    /// 参数说明:
    /// - text: 当前匹配始终使用的不可变正文树。
    /// 返回：空缓存，每轮查询独立持有，常驻最多八个正文叶片。
    init(_ text: PieceTree) {
        self.text = text
        count = text.utf16Count
    }

    /// 业务作用：为匹配器提供全局 UTF-16 单元访问，支持跨叶片断言、回溯和捕获引用。
    /// 参数说明:
    /// - position: 已由匹配边界约束的 UTF-16 单元索引。
    /// 返回：原始单元；缓存未命中时只读取一个叶片，非法内部索引拒绝继续执行。
    subscript(position: Int) -> UInt16 {
        if position >= start && position < end {
            return current[position - start]
        }
        for chunk in chunks {
            if position >= chunk.start && position - chunk.start < chunk.units.count {
                return chunk.units[position - chunk.start]
            }
        }
        // 先释放最旧叶片再分配新片段，回溯跨页不能逐步积存整篇正文的派生数据。
        if chunks.count == 8 {
            chunks.removeFirst()
        }
        guard let chunk = text.utf16Chunk(containing: position) else {
            preconditionFailure("匹配读取位置超出固定正文范围。")
        }
        chunks.append(chunk)
        current = chunk.units
        start = chunk.start
        end = start + current.count
        return current[position - start]
    }
}
