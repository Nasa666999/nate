import Foundation
import NateCore

extension CSSScanner {
    /// 业务作用：原字节消费同时保留有限候选、引号转义与真实物理边界，虚拟 EOF 不污染原文上下文。
    /// 参数说明: 无。
    /// 返回：完整标量消费；目标范围已稳定时交回安全边界，预算或来源不足时抛错。
    mutating func advance() throws {
        try requireCurrent()
        try budget.consume()
        if cursor == bytes.count {
            cursor += 1
            return
        }
        let count = width(at: cursor), value = current
        guard count <= bytes.count - cursor, state.segmentLength <= Int.max - count,
            value != 92 || state.backslashes < 2_097_152
        else {
            throw NateError.message("CSS 原字节或连续转义超过完整范围。")
        }
        if state.prefix.count < 99 {
            let retained = min(count, 99 - state.prefix.count)
            state.prefix.append(contentsOf: bytes[cursor..<cursor + retained])
        }
        state.segmentLength += count
        let ends: Bool
        if value == 10 {
            ends = true
        }
        else if value == 13 {
            ends = try next() != 10
        }
        else {
            ends = false
        }
        state.previousScalar = value
        state.backslashes = value == 92 ? state.backslashes + 1 : 0
        state.physicalBoundary = ends
        cursor += count
        if ends {
            lastBoundary = CSSPhysicalBoundary(
                offset: base + cursor,
                state: state
            )
            // 稳定类别不会被后继候选重新着色，物理边界已足够授予当前范围显示资格。
            if !prefixOnly, base + cursor >= wantedUpper, !Self.pending(state.mode) {
                safeBoundary = lastBoundary
                throw CSSScannerSignal.ready
            }
        }
    }

    /// 业务作用：SetState 完整封闭旧段并另开候选，未决分类不能改写已经封闭的历史范围。
    /// 参数说明:
    /// - mode: 当前字符开始采用的新原生类别。
    /// 返回：旧段按完整类别保留，新段清空候选；已确认目标物理边界时结束本批扫描。
    mutating func setMode(_ mode: UInt8) throws {
        try emit(until: min(cursor, bytes.count), style: state.mode)
        state.mode = mode
        state.segmentOrigin = base + min(cursor, bytes.count)
        state.segmentLength = 0
        state.prefix = []
        // 后继 SetState 只会影响它之后的字节，之前最近的完整物理边界可以原状态安全恢复。
        if !prefixOnly, let lastBoundary, lastBoundary.offset >= wantedUpper,
            lastBoundary.offset <= base + min(cursor, bytes.count)
        {
            safeBoundary = lastBoundary
            throw CSSScannerSignal.ready
        }
    }

    /// 业务作用：只交付由完整后继或真实 EOF 确认的缓存，截断缓冲区不授予部分颜色资格。
    /// 参数说明: 无。
    /// 返回：稳定边界及对应原状态和完整词元；缺少资格或超时则拒绝整份结果。
    mutating func finish() throws -> CSSScannedChunk {
        let upper: Int
        let restored: CSSLexicalState
        if let safeBoundary {
            upper = safeBoundary.offset
            restored = safeBoundary.state
        }
        else if prefixOnly || trueEOF {
            upper = base + bytes.count
            restored = state
        }
        else {
            throw NateError.message("CSS 未决词法段超过有界后继范围。")
        }
        try emit(until: min(cursor, bytes.count), style: state.mode)
        var output: [CSSCachedToken] = []
        for token in tokens {
            try budget.consume()
            if token.range.lower >= upper {
                break
            }
            output.append(
                CSSCachedToken(
                    range: ByteRange(token.range.lower, min(upper, token.range.upper)),
                    kind: token.kind,
                    style: token.style
                )
            )
        }
        // 全部类别、容量和边界确认后才交付，迟到取消不能留下半个分类段。
        try budget.check()
        return CSSScannedChunk(
            range: ByteRange(base, upper),
            state: restored,
            tokens: output
        )
    }
}
