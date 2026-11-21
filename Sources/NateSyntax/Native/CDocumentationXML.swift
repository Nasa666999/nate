import Foundation
import NateCore

extension CLexing {
    /// 业务作用：文档注释中的 XML 名称沿共享 C 词法规则独立分类，标签括号仍属于注释。
    /// 参数说明: 无。
    /// 返回：完整消费标签候选时为真；普通注释和非标签起点保持原处理流程。
    mutating func documentationXML() throws -> Bool {
        guard state.documentation else {
            return false
        }
        let byte = bytes[cursor]
        let next = cursor + 1 < bytes.count ? bytes[cursor + 1] : 0
        let previous = cursor > 0 ? bytes[cursor - 1] : 32
        let opening =
            byte == 60 && next != 47
            && (state.lineComment || ![9, 10, 11, 12, 13, 32].contains(next))
        guard opening || byte == 47 && previous == 60 else {
            return false
        }
        try emit(cursor, cursor + 1, kind: .comment, style: commentStyle)
        cursor += 1
        guard cursor < bytes.count else {
            return true
        }
        let start = cursor
        let first = bytes[start]
        let width = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
        var source = bytes
        if start + width == bytes.count, [10, 13].contains(first) || unicodeLineEnding {
            // XML 起点后的首标量独立消费；展示或物理分段之后仍可能属于同一名称，旧片段颜色须有后续证据。
            _ = try extendDocumentationXMLSource(&source)
        }
        var end = start + width
        var bracket = false
        var style = "documentationKeyword"
        var closesBlock = false
        while end < source.count {
            try budget.consume()
            let value = source[end]
            if value == 92, end + 1 < source.count, [10, 13].contains(source[end + 1]) {
                // C 续行先于文档命令分类；原字节保留在候选中，不能把两段名称拼成另一个已知命令。
                end += source[end + 1] == 13 && end + 2 < source.count && source[end + 2] == 10 ? 3 : 2
                if end == source.count {
                    _ = try extendDocumentationXMLSource(&source)
                }
                continue
            }
            if state.blockComment, value == 42, end + 1 < source.count, source[end + 1] == 47 {
                end += 2
                style = "documentationInvalid"
                closesBlock = true
                break
            }
            if value == 91 || value == 123 {
                bracket = true
            }
            let alphabetic = value >= 65 && value <= 90 || value >= 97 && value <= 122
            let allowed =
                alphabetic || [36, 64, 92, 38, 60, 62, 35, 123, 125, 91, 93].contains(value)
                || bracket && [44, 46].contains(value)
            if !allowed || value == 62 {
                let name = String(decoding: source[start..<end], as: UTF8.self)
                let suffix = String(decoding: source[(start + 1)..<end], as: UTF8.self)
                let valid =
                    value == 62
                    ? documentationKeywords.contains(name)
                    : [0, 9, 10, 11, 12, 13, 32].contains(value)
                        && (documentationKeywords.contains(name) || documentationKeywords.contains(suffix))
                style = valid ? "documentationKeyword" : "documentationInvalid"
                break
            }
            end += 1
        }
        if end == source.count {
            let name = String(decoding: source[start..<end], as: UTF8.self)
            let suffix = String(decoding: source[(start + 1)..<end], as: UTF8.self)
            style =
                documentationKeywords.contains(name) || documentationKeywords.contains(suffix)
                ? "documentationKeyword" : "documentationInvalid"
        }
        try emit(start, min(end, bytes.count), kind: .comment, style: style)
        state.xmlTerminator = !closesBlock && end < source.count && source[end] == 47
        if end >= bytes.count, source.count > bytes.count, let snapshot {
            state.xmlContinuation = CXMLContinuation(
                documentID: snapshot.id,
                revision: snapshot.revision,
                nextOffset: base + bytes.count,
                endOffset: base + end,
                style: style,
                closesBlock: closesBlock
            )
        }
        state.blockStar = false
        if closesBlock, end <= bytes.count {
            // 整个结束符已属于候选错误范围，先解除注释再让后续代码恢复自己的结构作用域。
            state.blockComment = false
            state.documentation = false
        }
        cursor = min(end, bytes.count)
        return true
    }

    /// 业务作用：跨行 XML 名称按需取得下一物理范围，所有后续证据绑定同一快照并受共同容量保护。
    /// 参数说明:
    /// - source: 原行及已经取得的连续原始字节，不允许省略中间内容。
    /// 返回：存在下一范围且完整加入时为真，固定正文已到末尾为假；缺少来源或超过 1 MiB 整体失败。
    mutating func extendDocumentationXMLSource(_ source: inout [UInt8]) throws -> Bool {
        try budget.check()
        guard let snapshot, base <= snapshot.text.byteCount - source.count else {
            throw NateError.message("C/C++ 文档 XML 跨行名称需要当前修订的完整原文证据。")
        }
        if source.count == bytes.count {
            // 后续片段直接来自同一不可变树，首段只需一次确认，避免短行扩展反复扫描长前缀。
            guard snapshot.text.isBoundary(base), snapshot.text.isBoundary(base + bytes.count),
                snapshot.text.bytes(in: ByteRange(base, base + bytes.count)).elementsEqual(bytes)
            else {
                throw NateError.message("C/C++ 文档 XML 首段与固定正文不一致。")
            }
        }
        let next = base + source.count
        guard next < snapshot.text.byteCount else {
            return false
        }
        let row = snapshot.text.lineRange(snapshot.text.lineNumber(at: next))
        let range = ByteRange(next, row.upper)
        guard range.count > 0, range.count <= 1_048_576 - source.count else {
            throw NateError.message("C/C++ 文档 XML 名称的共同向前范围超过 1 MiB。")
        }
        source.append(contentsOf: snapshot.text.bytes(in: range))
        return true
    }
}
