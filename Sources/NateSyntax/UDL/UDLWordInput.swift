import Foundation
import NateCore

final class UDLWordInput {
    private let initial: [UInt8]
    private let offset: Int
    private let base: Int
    private let snapshot: DocumentSnapshot?
    private let budget: UDLScanBudget
    private var following: [UInt8] = []

    /// 业务作用：短语优先读取已有物理行，只在需要后续证据时从固定正文按小块延伸。
    /// 参数说明:
    /// - initial: 当前完整片段的原字节。
    /// - offset: 本次短语起点在片段内的位置。
    /// - base: 当前片段的文档字节起点。
    /// - snapshot: 可选的同一固定正文，缺少时不读取片段以外内容。
    /// - budget: 本次完整词法扫描的共同资格。
    /// 返回：至多向短语起点之后读取 1 MiB 的独立证据窗口，不建立全文副本。
    init(initial: [UInt8], offset: Int, base: Int, snapshot: DocumentSnapshot?, budget: UDLScanBudget) {
        self.initial = initial
        self.offset = offset
        self.base = base
        self.snapshot = snapshot
        self.budget = budget
    }

    /// 业务作用：每次前瞻计入同一预算，跨行按完整 UTF-8 边界读取，不把容量边缘变成虚构结束符。
    /// 参数说明:
    /// - position: 相对当前短语起点的非负字节位置。
    /// 返回：原字节或真实来源末尾；容量、取消或来源不足时明确失败。
    func byte(at position: Int) throws -> UInt8? {
        try budget.consume()
        let available = initial.count - offset
        if position < available {
            return initial[offset + position]
        }
        guard let snapshot else {
            return nil
        }
        let absolute = base + offset + position
        guard absolute < snapshot.text.byteCount else {
            return nil
        }
        guard position < 1_048_576 else {
            // 缺少完整短语证据时不能将读取上限冒充实际单词结尾。
            throw NateError.message("UDL 短语前瞻超过 1 MiB，完整样式未发布。")
        }
        while position - available >= following.count {
            let lower = base + initial.count + following.count
            let remaining = 1_048_576 - (lower - base - offset)
            var upper = min(snapshot.text.byteCount, lower + min(4096, remaining))
            while upper > lower, !snapshot.text.isBoundary(upper) {
                upper -= 1
            }
            guard upper > lower else {
                throw NateError.message("UDL 短语前瞻缺少完整字符边界，样式未发布。")
            }
            try budget.consume(upper - lower)
            following += snapshot.text.text(in: ByteRange(lower, upper)).utf8
        }
        return following[position - available]
    }
}
