import Foundation
import NateCore

struct FilteredSearchResultBatch: Sendable {
    let batch: SearchResultBatchPresentation
    let files: [SearchResultFilePresentation]
    let notes: [FilteredSearchResultNote]
}

struct FilteredSearchResultNote: Sendable {
    let index: Int
    let text: String
}

struct SearchResultFilterOutput: Sendable {
    let batches: [FilteredSearchResultBatch]
    let visibleRows: Int
}

enum SearchResultFilter {
    /// 业务作用：在完整已有结果中按路径和上下文执行区分大小写的字节字面筛选，不重新读取源文件。
    /// 参数说明:
    /// - batches: 当前保留的不可变结果批次。
    /// - query: 已确认的完整筛选文本，最多 16 KiB。
    /// 返回：完整筛选后的分组与可定位数量；取消或超过五秒时不返回部分树。
    static func apply(
        _ batches: [SearchResultBatchPresentation],
        query: String
    ) throws -> SearchResultFilterOutput {
        guard query.utf8.count <= 16_384 else {
            throw NateError.message("结果筛选最多 16 KiB，当前已完成的结果保留。")
        }
        let matcher = ResultLiteralMatcher(query)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var output: [FilteredSearchResultBatch] = []
        var visibleRows = 0
        for batch in batches {
            try checkpoint(deadline)
            var files: [SearchResultFilePresentation] = []
            for file in batch.files {
                try checkpoint(deadline)
                let matchesFile =
                    try (query.isEmpty || matcher.contains(file.path ?? file.name, deadline: deadline))
                var rows: [SearchPreviewRow] = []
                for row in file.rows {
                    try checkpoint(deadline)
                    if try (matchesFile || matcher.contains(row.context, deadline: deadline)) {
                        rows.append(row)
                    }
                }
                if matchesFile || !rows.isEmpty {
                    files.append(
                        SearchResultFilePresentation(
                            id: file.id,
                            name: file.name,
                            path: file.path,
                            matchCount: file.matchCount,
                            rows: rows
                        )
                    )
                    visibleRows += rows.count
                }
            }
            var notes: [FilteredSearchResultNote] = []
            for (index, note) in batch.notes.enumerated() {
                try checkpoint(deadline)
                if try (query.isEmpty || matcher.contains(note, deadline: deadline)) {
                    notes.append(FilteredSearchResultNote(index: index, text: note))
                }
            }
            if query.isEmpty || !files.isEmpty || !notes.isEmpty {
                output.append(FilteredSearchResultBatch(batch: batch, files: files, notes: notes))
            }
        }
        try checkpoint(deadline)
        return SearchResultFilterOutput(batches: output, visibleRows: visibleRows)
    }

    /// 业务作用：筛选预算和真实任务取消共同约束每个文件和命中，旧筛选不能无限占用计算。
    /// 参数说明:
    /// - deadline: 整轮筛选的共享截止时刻。
    /// 返回：仍有执行资格时继续，否则整体终止。
    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("结果筛选超过五秒，当前已完成的结果保留。")
        }
    }
}

private struct ResultLiteralMatcher: Sendable {
    let needle: [UInt8]
    let prefixes: [Int]

    /// 业务作用：为一轮筛选建立可复用的前缀状态，重复字符不会让逐行匹配退化为反复回扫。
    /// 参数说明:
    /// - query: 已通过 16 KiB 容量限制的字面原文。
    /// 返回：独立的 UTF-8 前缀状态，不归一化 Unicode 或保留结果正文。
    init(_ query: String) {
        needle = Array(query.utf8)
        var table = [Int](repeating: 0, count: needle.count)
        var length = 0
        for index in needle.indices.dropFirst() {
            while length > 0 && needle[index] != needle[length] {
                length = table[length - 1]
            }
            if needle[index] == needle[length] {
                length += 1
            }
            table[index] = length
        }
        prefixes = table
    }

    /// 业务作用：逐字节扫描一个已有路径或上下文，不复制全文数组且周期检查取消与截止。
    /// 参数说明:
    /// - text: 当前有界结果字段。
    /// - deadline: 所有批次共用的计算截止。
    /// 返回：存在完整字面匹配时为真；不同 UTF-8 原文独立处理。
    func contains(_ text: String, deadline: ContinuousClock.Instant) throws -> Bool {
        guard !needle.isEmpty else {
            return true
        }
        var length = 0
        for (index, byte) in text.utf8.enumerated() {
            if index & 1023 == 0 {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw NateError.message("结果筛选超过五秒，当前已完成的结果保留。")
                }
            }
            while length > 0 && byte != needle[length] {
                length = prefixes[length - 1]
            }
            if byte == needle[length] {
                length += 1
                if length == needle.count {
                    return true
                }
            }
        }
        return false
    }
}
