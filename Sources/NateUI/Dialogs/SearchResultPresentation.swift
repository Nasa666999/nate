import Foundation
import NateCore

public struct SearchResultFilePresentation: Sendable {
    public let id: UUID
    public let name: String
    public let path: String?
    public let matchCount: Int
    public let rows: [SearchPreviewRow]

    /// 业务作用：将同一真实来源的命中组成文件分组，未命名文档保留独立身份而不伪造磁盘路径。
    /// 参数说明:
    /// - id: 本批次内稳定的来源身份。
    /// - name: 搜索开始时的文档名称。
    /// - path: 真实文件路径，未命名文档为空。
    /// - matchCount: 包含无法无损定位项的实际匹配数量。
    /// - rows: 与同一固定正文相对应的有界可定位预览。
    /// 返回：只含结果元数据的不可变分组，不持有正文或文件访问能力。
    public init(id: UUID, name: String, path: String?, matchCount: Int, rows: [SearchPreviewRow]) {
        self.id = id
        self.name = name
        self.path = path
        self.matchCount = matchCount
        self.rows = rows
    }
}

public struct SearchResultBatchPresentation: Sendable {
    public let id: UUID
    public let query: String
    public let scope: String
    public let files: [SearchResultFilePresentation]
    public let notes: [String]

    /// 业务作用：保存一轮已完成查询的独立范围和结果，多轮查询不会互相借用行号身份。
    /// 参数说明:
    /// - id: 本次查询的稳定批次身份。
    /// - query: 实际执行的完整查找表达式。
    /// - scope: 实际文档、目录或所选面板范围说明。
    /// - files: 原请求顺序排列的命中文件分组。
    /// - notes: 未读取、无法定位或零命中的真实说明。
    /// 返回：可独立保留、复制和筛选的不可变批次，发布前须检查完整容量与行身份。
    public init(
        id: UUID,
        query: String,
        scope: String,
        files: [SearchResultFilePresentation],
        notes: [String]
    ) {
        self.id = id
        self.query = query
        self.scope = scope
        self.files = files
        self.notes = notes
    }

    /// 业务作用：树形结果在呈现前整体验证身份、容量和高亮坐标，不接受会造成半棵树或越界着色的输入。
    /// 参数说明: 无。
    /// 返回：完整结果的 UTF-8 元数据容量；超过十万匹配、64 MiB 或存在重复身份时明确失败。
    public func validatedFootprint() throws -> Int {
        guard query.utf8.count <= 1024 * 1024, scope.utf8.count <= 16_384,
            files.count <= 100_000, notes.count <= 10_000
        else {
            throw NateError.message("搜索结果批次的范围、文件数或说明超过容量，未发布部分树。")
        }
        var bytes = query.utf8.count + scope.utf8.count
        var fileIDs: Set<UUID> = []
        var rowIDs: Set<UUID> = []
        var matches = 0
        for file in files {
            guard fileIDs.insert(file.id).inserted, file.name.utf8.count <= 16_384,
                (file.path?.utf8.count ?? 0) <= 16_384, file.matchCount > 0,
                file.matchCount >= file.rows.count,
                file.matchCount <= 100_000 - matches
            else {
                throw NateError.message("搜索结果文件身份、名称或匹配数量无效，未发布部分树。")
            }
            matches += file.matchCount
            bytes += file.name.utf8.count + (file.path?.utf8.count ?? 0)
            guard bytes <= 64 * 1024 * 1024 else {
                throw NateError.message("搜索结果元数据超过 64 MiB，未发布部分树。")
            }
            for row in file.rows {
                guard rowIDs.count < 100_000, rowIDs.insert(row.id).inserted,
                    row.line > 0, row.column > 0, row.context.utf8.count <= 32_768,
                    row.displayLabel.utf8.count <= 131_072
                else {
                    throw NateError.message("搜索结果行身份、位置或上下文超限，未发布部分树。")
                }
                if let highlight = row.highlight {
                    let length = row.context.utf16.count
                    guard highlight.location >= 0, highlight.location <= length,
                        highlight.length >= 0, highlight.length <= length - highlight.location
                    else {
                        throw NateError.message("搜索结果高亮坐标超出上下文，未发布部分树。")
                    }
                }
                bytes += row.context.utf8.count + row.displayLabel.utf8.count
                guard bytes <= 64 * 1024 * 1024 else {
                    throw NateError.message("搜索结果元数据超过 64 MiB，未发布部分树。")
                }
            }
        }
        for note in notes {
            let count = note.utf8.count
            guard count <= 64 * 1024 * 1024 - bytes else {
                throw NateError.message("搜索结果元数据超过 64 MiB，未发布部分树。")
            }
            bytes += count
        }
        guard bytes <= 64 * 1024 * 1024 else {
            throw NateError.message("搜索结果元数据超过 64 MiB，未发布部分树。")
        }
        return bytes
    }
}

public enum SearchResultLabel {
    /// 业务作用：文件标题、查询摘要和反馈中的控制字符按单行文字显示，复制路径仍使用独立原始值。
    /// 参数说明:
    /// - raw: 已受容量约束的名称、路径或反馈原文。
    /// - limit: 最多呈现的 Unicode 标量数，上限 16384，较长原文只影响显示摘要。
    /// 返回：不含换行、方向控制或 NUL 的可见摘要，不参与真实文件身份比较。
    public static func display(_ raw: String, limit: Int = 1024) -> String {
        var output = ""
        let maximum = min(16_384, max(0, limit))
        for (index, scalar) in raw.unicodeScalars.prefix(maximum + 1).enumerated() {
            if index == maximum {
                output += "…"
                break
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
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
