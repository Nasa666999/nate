import Foundation
import NateCore

extension UDLLexer {
    /// 业务作用：已确认短语的后续物理行只延续样式，不能重复触发折叠层级变化。
    /// 参数说明:
    /// - bytes: 当前完整片段。
    /// - base: 当前文档字节起点。
    /// - position: 当前片段内已消费位置。
    /// - state: 已通过来源校验的连续词法状态。
    /// - definition: 当前固定规则。
    /// - tokens: 本行待发布的完整样式。
    /// 返回：存在后续范围时推进位置及状态并返回真，否则保持不变。
    static func consumeContinuation(
        bytes: [UInt8],
        base: Int,
        position: inout Int,
        state: inout UDLState,
        definition: UDLDefinition,
        tokens: inout [SyntaxToken]
    ) -> Bool {
        guard var pending = state.wordContinuation else {
            return false
        }
        let start = position
        position = min(bytes.count, pending.end - base)
        emit(
            &tokens,
            start: base + start,
            end: base + position,
            style: pending.style,
            definition: definition,
            merge: pending.action == nil,
            foldMarker: pending.action.map {
                let action: SyntaxFoldAction =
                    $0 == .close && base + position == pending.end ? .close : .continuation
                return SyntaxFoldMarker(
                    action: action,
                    insideComment: pending.insideComment
                )
            }
        )
        pending.next = base + position
        if pending.next == pending.end, let tail = pending.tail, tail.end > pending.end {
            state.wordContinuation = UDLWordContinuation(
                next: pending.end,
                end: tail.end,
                style: tail.style,
                action: nil,
                insideComment: pending.insideComment,
                documentID: pending.documentID,
                revision: pending.revision,
                sourceIdentity: pending.sourceIdentity,
                tail: nil
            )
        }
        else {
            state.wordContinuation = pending.next == pending.end ? nil : pending
        }
        return true
    }

    /// 业务作用：完整短语已取得终止证据后，当前片段先发布样式，剩余范围绑定同一不可变正文。
    /// 参数说明:
    /// - match: 已按优先级确认的完整短语。
    /// - bytes: 当前连续片段。
    /// - base: 当前文档字节起点。
    /// - position: 当前片段内消费位置。
    /// - state: 本次扫描的候选上下文。
    /// - source: 短语取得前瞻证据的固定正文。
    /// - replay: 首段已识别的前向动作，须在短语之后完成其消费和上下文变化。
    /// - definition: 本次固定规则。
    /// - tokens: 待一次发布的样式。
    /// 返回：推进当前范围；跨片段时记录来源身份及唯一的后续范围。
    static func consumeQuoted(
        _ match: UDLQuotedMatch,
        bytes: [UInt8],
        base: Int,
        position: inout Int,
        state: inout UDLState,
        source: DocumentSnapshot?,
        replay: UDLQuotedReplay?,
        definition: UDLDefinition,
        tokens: inout [SyntaxToken]
    ) {
        let start = position
        let end = base + start + match.length
        let insideComment = state.contexts.last?.style.contains("COMMENT") == true
        position = min(bytes.count, start + match.length)
        emit(
            &tokens,
            start: base + start,
            end: base + position,
            style: match.style,
            definition: definition,
            merge: match.action == nil,
            foldMarker: match.action.map {
                // 跨行闭合短语的全部物理行属于当前块，只有取得末段的行才解除该折叠层级。
                let action: SyntaxFoldAction = $0 == .close && end > base + bytes.count ? .continuation : $0
                return SyntaxFoldMarker(
                    action: action,
                    insideComment: insideComment
                )
            }
        )
        if replay?.pop == true {
            state.contexts.removeLast()
        }
        if let context = replay?.push {
            state.contexts.append(context)
        }
        let tail = replay.map {
            var upper = min(source?.text.byteCount ?? base + bytes.count, end + $0.length)
            if let source {
                while upper < source.text.byteCount, !source.text.isBoundary(upper) {
                    upper += 1
                }
            }
            else {
                while upper < base + bytes.count, bytes[upper - base] & 0xC0 == 0x80 {
                    upper += 1
                }
            }
            return UDLWordTail(
                end: upper,
                style: $0.style
            )
        }
        if end > base + bytes.count, let source {
            // 后续行只接受同一份正文证据；折叠动作已在开端执行，后续范围只保留结构归属。
            state.wordContinuation = UDLWordContinuation(
                next: base + position,
                end: end,
                style: match.style,
                action: match.action,
                insideComment: insideComment,
                documentID: source.id,
                revision: source.revision,
                sourceIdentity: source.text.sourceIdentity,
                tail: tail
            )
        }
        else if let tail, tail.end > end {
            let upper = min(base + bytes.count, tail.end)
            emit(&tokens, start: end, end: upper, style: tail.style, definition: definition)
            position = upper - base
            if tail.end > upper, let source {
                state.wordContinuation = UDLWordContinuation(
                    next: upper,
                    end: tail.end,
                    style: tail.style,
                    action: nil,
                    insideComment: insideComment,
                    documentID: source.id,
                    revision: source.revision,
                    sourceIdentity: source.text.sourceIdentity,
                    tail: nil
                )
            }
        }
    }
}
