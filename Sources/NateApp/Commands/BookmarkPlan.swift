import Foundation
import NateCore

struct BookmarkPlan: Sendable {
    let transaction: PreparedTransaction?
    let bookmarks: Set<Int>?
    let copiedText: String?
    let affectedLines: Int

    /// 业务作用：对固定书签集合准备完整行操作，删除非书签行只构造保留区间的补集，不枚举全部正文行。
    /// 参数说明:
    /// - action: 明确的批量动作，未知命令不能进入删除分支。
    /// - snapshot: 动作开始时的固定正文。
    /// - bookmarks: 原正文中的零起始逻辑行。
    /// - generation: 原书签身份，正文事务发布前必须仍然有效。
    /// - replacement: 替换动作使用的完整剪贴板正文，原行结束符保留。
    /// - permit: 后台动作仍拥有的执行资格。
    /// 返回：有界完整计划；超限、取消或非法行不产生部分正文与剪贴板内容。
    static func prepare(
        action: BookmarkAction,
        snapshot: DocumentSnapshot,
        bookmarks: Set<Int>,
        generation: UUID,
        replacement: String?,
        permit: @escaping @Sendable () -> Bool
    ) throws -> BookmarkPlan {
        let budget = BookmarkBudget(permit: permit)
        try budget.check()
        let tree = snapshot.text
        guard bookmarks.count <= 100_000,
            bookmarks.allSatisfy({
                $0 >= 0 && $0 < tree.lineCount
            })
        else {
            throw NateError.message("书签集合超出有效行或十万项容量，原文保留。")
        }
        var comparisons = 0
        let lines = try bookmarks.sorted {
            comparisons += 1
            if comparisons & 1023 == 0 {
                try budget.check()
            }
            return $0 < $1
        }
        if action == .invert {
            // 先检查补集容量；超大文档不能为了得出拒绝结果而遍历数百万行。
            guard tree.lineCount - lines.count <= 100_000 else {
                throw NateError.message("反转后书签超过十万行，原集合保留。")
            }
            var inverted: Set<Int> = []
            for row in 0..<tree.lineCount {
                if row & 255 == 0 {
                    try budget.check()
                }
                if !bookmarks.contains(row) {
                    inverted.insert(row)
                }
            }
            return BookmarkPlan(
                transaction: nil,
                bookmarks: inverted,
                copiedText: nil,
                affectedLines: inverted.count
            )
        }
        guard action.changesText || action == .copy else {
            throw NateError.message("该书签动作不属于批量行操作。")
        }
        guard !lines.isEmpty || action == .deleteOthers else {
            throw NateError.message("当前没有书签行，正文和剪贴板保留。")
        }
        var copied: String?
        if action.changesClipboard {
            var output = ""
            var remaining = 64 * 1024 * 1024
            for line in lines {
                try budget.check()
                let range = tree.lineRange(line)
                guard range.count <= remaining else {
                    throw NateError.message("书签行复制超过 64 MiB，剪贴板和正文保留。")
                }
                remaining -= range.count
                var offset = range.lower
                while offset < range.upper {
                    try budget.check()
                    var end = min(range.upper, offset + 65_536)
                    while !tree.isBoundary(end) {
                        end -= 1
                    }
                    output += tree.text(in: ByteRange(offset, end))
                    offset = end
                }
            }
            copied = output
        }
        guard action.changesText else {
            try budget.check()
            return BookmarkPlan(
                transaction: nil,
                bookmarks: nil,
                copiedText: copied,
                affectedLines: lines.count
            )
        }
        var edits: [TextEdit] = []
        if action == .replace {
            guard let replacement else {
                throw NateError.message("剪贴板没有可用文本，书签行保留。")
            }
            let bytes = replacement.utf8.count
            guard bytes <= 64 * 1024 * 1024,
                bytes == 0 || lines.count <= 256 * 1024 * 1024 / bytes
            else {
                throw NateError.message("剪贴板超过 64 MiB 或书签替换输出超过 256 MiB，原文保留。")
            }
            var removed = 0
            for line in lines {
                try budget.check()
                let range = tree.lineRange(line, includeEnding: false)
                removed += range.count
                edits.append(TextEdit(range, replacement))
            }
            guard tree.byteCount - removed + bytes * lines.count <= 1024 * 1024 * 1024 else {
                throw NateError.message("书签替换后的正文超过 1 GiB，原文保留。")
            }
        }
        else {
            var ranges: [ByteRange] = []
            var cursor = 0
            for line in lines {
                try budget.check()
                let range = tree.lineRange(line)
                if action == .deleteOthers {
                    if cursor < range.lower {
                        ranges.append(ByteRange(cursor, range.lower))
                    }
                    cursor = range.upper
                }
                else if !range.isEmpty {
                    if let last = ranges.last, last.upper == range.lower {
                        ranges[ranges.count - 1] = ByteRange(last.lower, range.upper)
                    }
                    else {
                        ranges.append(range)
                    }
                }
            }
            if action == .deleteOthers, cursor < tree.byteCount {
                ranges.append(ByteRange(cursor, tree.byteCount))
            }
            edits = ranges.map {
                TextEdit($0, "")
            }
        }
        try budget.check()
        let prepared = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            name: action == .replace ? "替换书签行" : "删除书签行"
        )
        var remaining: Set<Int> = []
        if action == .replace || action == .deleteOthers {
            let positions = try PositionMap(edits: edits)
            for line in lines {
                try budget.check()
                // 行首锚点属于替换前侧，整份剪贴板包含多行时书签仍落在插入内容的第一行。
                let start = positions.map(tree.lineStart(line), affinity: .before)
                remaining.insert(prepared.resultingText.lineNumber(at: start))
            }
        }
        let transaction = try prepared.assigningBookmarks(remaining, expectedGeneration: generation)
        try budget.check()
        return BookmarkPlan(
            transaction: transaction,
            bookmarks: nil,
            copiedText: copied,
            affectedLines: action == .deleteOthers ? tree.lineCount - lines.count : lines.count
        )
    }
}

private struct BookmarkBudget {
    let permit: @Sendable () -> Bool
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    /// 业务作用：在后台扫描、排序和构建正文的边界共用取消及时间预算。
    /// 参数说明: 无。
    /// 返回：任务仍有效时继续，否则整份计划停止且不发布部分结果。
    func check() throws {
        guard permit(), !Task.isCancelled else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("书签行操作超过五秒，正文与剪贴板保留。")
        }
    }
}
