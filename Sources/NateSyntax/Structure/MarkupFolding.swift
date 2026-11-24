import Foundation
import NateCore

enum MarkupFolding {
    /// 业务作用：以已闭合的标记元素、真实注释、CDATA 和 DOCTYPE 建立原生物理行折叠。
    /// 参数说明:
    /// - snapshot: 折叠视图固定的完整原文。
    /// - dialect: 采用真实 HTML 或 XML 边界，HTML 可记录已确认结束的可省略元素。
    /// - deadline: 标签读取、范围归并及结果发布的共同截止。
    /// 返回：完整且有界的多行范围；预算、容量或取消不满足时不隐藏部分原文。
    static func regions(
        snapshot: DocumentSnapshot,
        dialect: MarkupDialect,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let text = snapshot.text
        guard text.lineCount <= 1_048_576, text.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("标记语言折叠超过一百万行或 64 MiB 原文。")
        }

        /// 业务作用：同一计算截止控制读入、作用域和最后的折叠发布。
        /// 参数说明: 无。
        /// 返回：资格有效时继续；取消或超时会拒绝完整范围。
        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("标记语言折叠超过计算截止，原可见范围保持。")
            }
        }
        var lexer = MarkupIndentationLexer(dialect: dialect)
        var scope = MarkupIndentationScope(dialect: dialect)
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
                throw NateError.message("标记语言折叠超过 65536 个完整多行结构。")
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
                throw NateError.message("标记语言折叠的单个物理行超过 1 MiB。")
            }
            let noPrefix = ByteRange(row.lower, row.lower)
            for (offset, byte) in text.bytes(in: row).enumerated() {
                if offset & 255 == 0 {
                    try check()
                }
                let previous = lexer.mode
                if let tag = lexer.consume(byte, at: row.lower + offset, prefix: noPrefix) {
                    /// 业务作用：在 HTML 真实后继之前停止可省略结束标签的范围，后继保持可见。
                    /// 参数说明:
                    /// - frame: 已由同一作用域确认隐式结束的原元素。
                    /// 返回：记录完整行变化；范围或预算不足时停止本次折叠。
                    func impliedEnd(_ frame: MarkupIndentationScope.Frame) throws {
                        let boundary = text.lineNumber(at: tag.range.lower)
                        try record(text.lineNumber(at: frame.anchor), boundary - 1)
                    }
                    switch tag.kind {
                    case .open, .empty:
                        try scope.open(tag, impliedEnd: impliedEnd, check: check)
                    case .close:
                        if let opening = try scope.close(tag, impliedEnd: impliedEnd, check: check) {
                            try record(text.lineNumber(at: opening.anchor), line)
                        }
                        else if dialect == .xml {
                            // 错配后不能跨过已经失去结构资格的标签继续隐藏原文。
                            scope.discardOpenElements()
                        }
                    }
                }
                let mode = lexer.mode
                if previous == mode {
                    continue
                }
                if mode == .comment || mode == .cdata && (dialect == .xml || scope.hasForeignContent) {
                    literalStart = line
                }
                else if previous == .comment || previous == .cdata, let start = literalStart {
                    literalStart = nil
                    try record(start, line)
                }
                if previous == .bang, mode == .declaration, let start = lexer.constructStart,
                    isDoctype(at: start, in: row, text: text, dialect: dialect)
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

    /// 业务作用：只为真实 DOCTYPE 的完整声明建立折叠，属性和其它声明各自保留原范围。
    /// 参数说明:
    /// - start: 原始标记的尖括号字节位置。
    /// - row: 当前真实物理行范围。
    /// - text: 同一固定正文。
    /// - dialect: 当前名称比较采用的标记语言规则。
    /// 返回：ASCII 关键字和紧随分隔符都匹配时成立。
    private static func isDoctype(at start: Int, in row: ByteRange, text: PieceTree, dialect: MarkupDialect)
        -> Bool
    {
        guard row.upper - start >= 10, let next = text.byte(at: start + 9), MarkupTag.whitespace(next) else {
            return false
        }
        let raw = text.bytes(in: ByteRange(start, start + 9))
        return dialect == .html
            ? MarkupNames.folded(raw).elementsEqual("<!doctype".utf8) : raw.elementsEqual("<!DOCTYPE".utf8)
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
                    throw NateError.message("标记语言折叠的完整物理范围超量或失去层级证据。")
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
            throw NateError.message("标记语言折叠缺少完整闭合证据。")
        }
        try check()
        return output
    }
}
