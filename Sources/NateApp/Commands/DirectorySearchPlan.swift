import Foundation
import NateCore
import NateStorage
import NateUI

enum DirectorySearchPlanFailure: Error, LocalizedError {
    case matches, replacements

    /// 业务作用：把整轮目录计划超限与文件读取失败区分，调用方不能把部分计划当作完整查询。
    /// 参数说明: 无。
    /// 返回：用户可据以缩小查询范围的资源限制。
    var errorDescription: String? {
        switch self {
        case .matches:
            return "目录查询合计超过 100000 个命中，请缩小范围；未发布部分计划。"
        case .replacements:
            return "目录替换文本合计超过 256 MiB，请缩小范围；文件未修改。"
        }
    }
}

struct DirectorySearchPlanBudget: Sendable {
    private(set) var hitCount = 0
    private(set) var replacementBytes = 0

    /// 业务作用：为整轮目录查询预留命中容量，防止每个文件各自取得完整额度。
    /// 参数说明:
    /// - count: 当前文件的完整命中数量。
    /// 返回：累计不超过十万时记录容量；超限终止整个未发布计划。
    mutating func reserveHits(_ count: Int) throws {
        guard count >= 0, count <= 100_000 - hitCount else {
            throw DirectorySearchPlanFailure.matches
        }
        hitCount += count
    }

    /// 业务作用：限制确认前保留的替换正文，打开与关闭文件共用同一输出容量。
    /// 参数说明:
    /// - edits: 单个固定快照的完整替换意图。
    /// - permit: 当前查询在独立队列中的取消权限。
    /// 返回：累计输出不超过 256 MiB 时记录容量；取消或超限不授予任何文件写入权。
    mutating func reserveReplacements(
        _ edits: [TextEdit],
        permit: @Sendable () -> Bool
    ) throws {
        for (index, edit) in edits.enumerated() {
            if index & 255 == 0 {
                try Task.checkCancellation()
                guard permit() else {
                    throw CancellationError()
                }
            }
            let bytes = edit.text.utf8.count
            guard bytes <= 256 * 1024 * 1024 - replacementBytes else {
                throw DirectorySearchPlanFailure.replacements
            }
            replacementBytes += bytes
        }
    }
}

struct DirectoryPlan: Sendable {
    static let maximumSourceBytes = 1024 * 1024 * 1024
    let url: URL
    let baseline: DiskBaseline
    let encoding: TextEncoding
    let documentID: UUID?
    let revision: UInt64?
    let hitCount: Int
    let edits: [TextEdit]
    let prepared: PreparedTransaction?
    let previews: [SearchPreviewRow]

    /// 业务作用：确认后逐个重读关闭文件，原基线与编码仍成立才允许备份和覆盖，不在整轮计划中保留原字节与正文树。
    /// 参数说明:
    /// - access: 保持原路径和系统协调一致的文件入口。
    /// - operations: 记录备份和目标各自真实发布阶段的任务登记。
    /// - catalog: 当前应用的严格代码页映射。
    /// - token: 当前文件操作的取消和单次发布权限。
    /// 返回：原字节副本先持久化，目标随后按原基线发布；任何证据变化都拒绝覆盖。
    func replaceFile(
        using access: CoordinatedFileAccess,
        operations: FileOperationLedger,
        catalog: LegacyCodecCatalog?,
        token: CancellationToken
    ) throws {
        try token.check()
        // 打开文档的修改必须走可撤销事务，不能借重读路径绕开缓冲区生命周期。
        guard documentID == nil else {
            throw NateError.message("打开缓冲区不能使用关闭文件写入通道。")
        }
        let loaded = try access.load(
            url,
            encoding: encoding,
            catalog: catalog,
            maximumBytes: Self.maximumSourceBytes,
            permit: {
                !token.isCancelled
            }
        )
        // 原身份、完整字节和解码规则决定替换坐标，确认后改变任一证据都不能复用旧偏移。
        guard loaded.baseline == baseline, loaded.encoding == encoding else {
            throw NateError.message("文件在计划后已改变，原文件未覆盖，请重新生成替换计划。")
        }
        var tree = loaded.tree
        for (index, edit) in edits.reversed().enumerated() {
            if index & 255 == 0 {
                try token.check()
            }
            tree = try tree.replacing(edit.range, with: edit.text)
        }
        try token.check()
        let data = try loaded.encoding.encode(tree.text(), catalog: catalog)
        try token.check()
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + "." + UUID().uuidString + ".nate-backup"
        )
        // 原字节副本先取得独立发布确认，随后目标才能申请自己的单次发布权。
        try token.withChild {
            request in
            _ = try operations.save(
                using: access,
                loaded.originalBytes,
                to: backup,
                expected: nil,
                permit: {
                    !request.isCancelled
                },
                authority: request
            )
        }
        try token.withChild {
            request in
            _ = try operations.save(
                using: access,
                data,
                to: url,
                expected: baseline,
                permit: {
                    !request.isCancelled
                },
                authority: request
            )
        }
    }
}
