import Foundation
import NateCore
import NateSearch

public enum SearchPreviewFailure: Error, LocalizedError, Sendable {
    case matches, output, label, computation

    /// 业务作用：明确区分结果展示预算与零命中，超限时调用方不能发布部分结果。
    /// 参数说明: 无。
    /// 返回：可用于缩小范围或改用计数的具体失败原因。
    public var errorDescription: String? {
        switch self {
        case .matches: return "结果展示超过 100000 个命中，请缩小范围或使用计数。"
        case .output: return "匹配结果文本超过 32 MiB，请缩小范围或使用计数。"
        case .label: return "结果文件名或路径超过 16 KiB，未生成部分结果。"
        case .computation: return "结果预览超过 5 秒计算预算，请缩小搜索范围。"
        }
    }
}

public struct SearchPreviewRow: Sendable {
    public let id: UUID
    public let range: ByteRange
    public let displayLabel: String
    public let line: Int
    public let column: Int
    public let context: String
    public let highlight: NSRange?

    /// 业务作用：复制或文本输出时从有界展示字段生成完整单行结果，树形呈现不额外保存同一份拼接文字。
    /// 参数说明: 无。
    /// 返回：安全文件标签、从一开始的行号和 UTF-16 列号及原始上下文摘要。
    public var text: String {
        "\(displayLabel):\(line) [UTF-16 列 \(column)]  \(context)"
    }
}

public struct SearchResultPreviewBuilder: Sendable {
    public private(set) var matchCount = 0
    public private(set) var utf8Count = 0
    public private(set) var unmappedCount = 0
    private var remaining = Duration.seconds(5)
    private let permit: @Sendable () -> Bool

    /// 业务作用：让同一查询的多个文档共用结果容量和实际预览计算时间，不持有正文快照。
    /// 参数说明:
    /// - permit: 队列执行期间仍然有效的显式请求权限。
    /// 返回：空展示预算，后续只保留计数，不保留已生成的文字或文档。
    public init(
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) {
        self.permit = permit
    }

    /// 业务作用：在后台为匹配生成与可导航范围一一对应的安全单行预览，超长行只读取命中附近片段。
    /// 参数说明:
    /// - hits: 来自同一固定正文的完整匹配证据。
    /// - text: 与匹配坐标一致的不可变正文树。
    /// - label: 查询开始时的文件路径或文档名称。
    /// 返回：合法 UTF-8 范围对应的单行结果；无法映射的 UTF-16 命中单独计数，预算或取消失败不返回部分行。
    public mutating func prepare(_ hits: [SearchHit], text: PieceTree, label: String) throws
        -> [SearchPreviewRow]
    {
        try Task.checkCancellation()
        // 独立 I/O 队列不继承 Swift Task 取消状态，展示构建也必须复验原请求令牌。
        guard permit() else {
            throw CancellationError()
        }
        guard !hits.isEmpty else {
            return []
        }
        let began = ContinuousClock.now
        let deadline = began.advanced(by: remaining)
        defer {
            remaining = max(.zero, remaining - began.duration(to: .now))
        }
        guard label.utf8.count <= 16_384 else {
            throw SearchPreviewFailure.label
        }
        let label = try escaped(label, deadline: deadline)
        var rows: [SearchPreviewRow] = []
        for hit in hits {
            try checkpoint(deadline)
            guard matchCount < 100_000 else {
                throw SearchPreviewFailure.matches
            }
            matchCount += 1
            // 半代理项没有可导航的 UTF-8 区间，保留计数但不能制造替代范围供点击。
            guard let range = hit.range else {
                unmappedCount += 1
                continue
            }
            // 展示与导航共用同一标量范围，伪造或已经失效的坐标不能显示为另一个可点击命中。
            guard text.byteRange(hit.utf16Range) == range else {
                throw NateError.invalidRange
            }
            let line = text.lineNumber(at: range.lower)
            let body = text.lineRange(line, includeEnding: false)
            let center = min(range.lower, body.upper)
            var start = center - min(256, center - body.lower)
            while !text.isBoundary(start) {
                start -= 1
            }
            var end = start + min(2048, body.upper - start)
            while !text.isBoundary(end) {
                end -= 1
            }
            // 先限定字节再建立 String，不能为了显示几百字复制整条日志行或整个文件。
            let raw = text.text(
                in: ByteRange(
                    start,
                    end
                )
            )
            let shown = String(raw.prefix(500))
            var preview = try escaped(shown, deadline: deadline)
            if preview.isEmpty {
                preview = "（空行）"
            }
            if start > body.lower {
                preview = "…" + preview
            }
            if end < body.upper || shown.utf8.count < raw.utf8.count {
                preview += "…"
            }
            var highlight = try contextHighlight(
                range,
                text: text,
                start: start,
                upper: min(body.upper, start + shown.utf8.count),
                leadingEllipsis: start > body.lower,
                deadline: deadline
            )
            if range.isEmpty {
                highlight = NSRange(location: preview.utf16.count + 1, length: "[空匹配]".utf16.count)
                preview += " [空匹配]"
                if range.lower > body.upper {
                    preview += " [换行内]"
                }
            }
            else if range.upper > body.upper {
                if highlight == nil {
                    highlight = NSRange(location: preview.utf16.count + 1, length: "[含换行]".utf16.count)
                }
                preview += " [含换行]"
            }
            guard let position = text.utf16Offset(byte: range.lower),
                let lineStart = text.utf16Offset(byte: body.lower)
            else {
                throw NateError.invalidRange
            }
            let row = "\(label):\(line + 1) [UTF-16 列 \(position - lineStart + 1)]  \(preview)"
            let bytes = row.utf8.count
            // 每行连同分隔符一起预留，跨文件查询不能通过分批生成重新取得完整输出额度。
            guard bytes < 32 * 1024 * 1024 - utf8Count else {
                throw SearchPreviewFailure.output
            }
            utf8Count += bytes + 1
            rows.append(
                SearchPreviewRow(
                    id: UUID(),
                    range: range,
                    displayLabel: label,
                    line: line + 1,
                    column: position - lineStart + 1,
                    context: preview,
                    highlight: highlight
                )
            )
        }
        try checkpoint(deadline)
        return rows
    }

    /// 业务作用：结果高亮映射到转义后的可见上下文，控制字符不能使着色范围偏离实际命中。
    /// 参数说明:
    /// - range: 固定正文中的完整命中。
    /// - text: 生成结果时的正文树。
    /// - start: 有界上下文的起始字节。
    /// - upper: 实际显示的首行正文终点。
    /// - leadingEllipsis: 上下文前是否有省略号。
    /// - deadline: 本轮预览的共享截止时刻。
    /// 返回：可见交集在转义文本中的 UTF-16 范围；仅换行或空匹配由调用者显示明确标识。
    private func contextHighlight(
        _ range: ByteRange,
        text: PieceTree,
        start: Int,
        upper: Int,
        leadingEllipsis: Bool,
        deadline: ContinuousClock.Instant
    ) throws -> NSRange? {
        let lower = max(start, range.lower)
        let end = min(upper, range.upper)
        guard lower < end else {
            return nil
        }
        let prefix = try escaped(text.text(in: ByteRange(start, lower)), deadline: deadline)
        let match = try escaped(text.text(in: ByteRange(lower, end)), deadline: deadline)
        return NSRange(
            location: prefix.utf16.count + (leadingEllipsis ? 1 : 0),
            length: match.utf16.count
        )
    }

    /// 业务作用：在片段和行边界限制实际计算，取消后不继续构建大批展示数据。
    /// 参数说明:
    /// - deadline: 本段剩余预览时间对应的真实截止时刻。
    /// 返回：调用权和计算时间仍然有效时继续，否则终止整个展示计划。
    private func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        // 展示也可能在独立队列中计算，显式调用权失效后不能继续生成迟到的大批结果。
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw SearchPreviewFailure.computation
        }
    }

    /// 业务作用：把行内控制和方向控制转为可见文字，避免文件名或正文制造额外结果行、错位导航或隐藏的路径显示。
    /// 参数说明:
    /// - text: 已有字节上限的标签或正文片段。
    /// - deadline: 当前片段的真实计算截止。
    /// 返回：只含一个展示行的文本，保留 Unicode 标量顺序，不归一化正文。
    private func escaped(_ text: String, deadline: ContinuousClock.Instant) throws -> String {
        var output = ""
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if index & 255 == 0 {
                try checkpoint(deadline)
            }
            switch scalar.value {
            case 0: output += "\\0"
            case 9: output += "\\t"
            case 10: output += "\\n"
            case 13: output += "\\r"
            case 92: output += "\\\\"
            case 1...8, 11...12, 14...31, 127...159, 0x061c, 0x200e...0x200f,
                0x2028...0x202e, 0x2066...0x2069:
                output += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
