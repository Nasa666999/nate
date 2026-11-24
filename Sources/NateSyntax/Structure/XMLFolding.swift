import Foundation
import NateCore

enum XMLFolding {
    private struct Element {
        let name: [UInt8]
        let line: Int
    }

    /// 业务作用：仅以已闭合的 XML 元素、真实注释、CDATA 和 DOCTYPE 建立原生物理行折叠。
    /// 参数说明:
    /// - snapshot: 折叠视图固定的完整原文。
    /// - deadline: 标签读取、范围归并及结果发布的共同截止。
    /// 返回：完整且有界的多行范围；预算、容量或取消不满足时不隐藏部分原文。
    static func regions(snapshot: DocumentSnapshot, deadline: ContinuousClock.Instant) throws -> [FoldRegion]
    {
        let text = snapshot.text
        guard text.lineCount <= 1_048_576, text.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("XML 折叠超过一百万行或 64 MiB 原文。")
        }

        /// 业务作用：同一计算截止控制读入、作用域和最后的折叠发布。
        /// 参数说明: 无。
        /// 返回：资格有效时继续；取消或超时会拒绝完整范围。
        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("XML 折叠超过计算截止，原可见范围保持。")
            }
        }
        var lexer = MarkupIndentationLexer(dialect: .xml)
        var elements: [Element] = []
        var changes: [Int: Int] = [:]
        var blockCount = 0
        var literalStart: Int?
        var declarationStart: Int?

        /// 业务作用：只在通过配对确认后登记物理行变化，同行开闭不会生成折叠。
        /// 参数说明:
        /// - start: 已确认结构开始定界的物理行。
        /// - end: 已确认结构结束定界的物理行。
        /// 返回：一对完整的层级增减；记录超量时整份停止。
        func record(_ start: Int, _ end: Int) throws {
            guard start < end else {
                return
            }
            guard blockCount < 65_536 else {
                throw NateError.message("XML 折叠超过 65536 个完整多行结构。")
            }
            blockCount += 1
            changes[start, default: 0] += 1
            changes[end, default: 0] -= 1
        }

        for line in 0..<text.lineCount {
            try check()
            let row = text.lineRange(line)
            // 未知长行可能包含开端或闭合，不能用此前的层级隐藏这行后的正文。
            guard row.count <= 1024 * 1024 else {
                throw NateError.message("XML 折叠的单个物理行超过 1 MiB。")
            }
            let noPrefix = ByteRange(row.lower, row.lower)
            for (offset, byte) in text.bytes(in: row).enumerated() {
                if offset & 255 == 0 {
                    try check()
                }
                let previous = lexer.mode
                if let tag = lexer.consume(byte, at: row.lower + offset, prefix: noPrefix) {
                    switch tag.kind {
                    case .open:
                        // 活动栈超量或缺失时不得用未保留的外层为任何折叠授予资格。
                        guard elements.count < 4096 else {
                            throw NateError.message("XML 折叠的活动元素超过 4096 层。")
                        }
                        elements.append(Element(name: tag.name, line: line))
                    case .close:
                        if let opening = elements.last, opening.name == tag.name {
                            elements.removeLast()
                            try record(opening.line, line)
                        }
                        else {
                            // 错配后不能跨过已经失去结构资格的标签继续隐藏原文。
                            elements.removeAll(keepingCapacity: true)
                        }
                    case .empty:
                        break
                    }
                }
                let mode = lexer.mode
                if previous == mode {
                    continue
                }
                if mode == .comment || mode == .cdata {
                    literalStart = line
                }
                else if previous == .comment || previous == .cdata, let start = literalStart {
                    literalStart = nil
                    try record(start, line)
                }
                if previous == .bang, mode == .declaration, let start = lexer.constructStart,
                    row.upper - start >= 10,
                    text.bytes(in: ByteRange(start, start + 9)).elementsEqual("<!DOCTYPE".utf8),
                    let following = text.byte(at: start + 9), MarkupTag.whitespace(following)
                {
                    declarationStart = line
                }
                else if previous == .declaration, mode == .data, let start = declarationStart {
                    declarationStart = nil
                    try record(start, line)
                }
            }
        }
        return try physicalRegions(changes: changes, text: text, check: check)
    }

    /// 业务作用：按同一物理行全部开闭的净层级计算可见标题，避免同行相邻元素产生交叉折叠。
    /// 参数说明:
    /// - changes: 只包含真实匹配结构的物理行层级变化。
    /// - text: 与变化拥有同一来源的原始正文。
    /// - check: 当前计算的继续资格。
    /// 返回：完整且无交叉的行折叠候选；取消和超量时整体失败。
    private static func physicalRegions(changes: [Int: Int], text: PieceTree, check: () throws -> Void)
        throws -> [FoldRegion]
    {
        var output: [FoldRegion] = []
        var pending: [(line: Int, depth: Int)] = []
        var level = 0
        for line in changes.keys.sorted() {
            try check()
            let after = level + changes[line, default: 0]
            if after > level {
                pending.append((line, level))
            }
            while let header = pending.last, after <= header.depth {
                try check()
                pending.removeLast()
                guard output.count < 65_536, header.line < line else {
                    throw NateError.message("XML 折叠的完整物理范围超量或失去层级证据。")
                }
                output.append(
                    FoldRegion(
                        range: ByteRange(text.lineStart(header.line), text.lineRange(line).upper),
                        startLine: header.line,
                        endLine: line,
                        level: 0
                    )
                )
            }
            level = after
        }
        // 全部变化必须成对耗尽，未验证的范围不能交付给视图用于隐藏正文。
        guard level == 0, pending.isEmpty else {
            throw NateError.message("XML 折叠缺少完整闭合证据。")
        }
        try check()
        return output
    }
}
