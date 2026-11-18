import Foundation
import NateCore
import NateSearch
import NateStorage
import NateUI

enum FileSearchSource: Sendable {
    case directory(URL)
    case projectReferences([ProjectSearchPanelCapture])
    case projects(files: [URL], failures: [String], panels: [Int])

    /// 业务作用：反馈只列出真正参与本次请求的目录或面板，不把未载入面板算入范围。
    /// 参数说明: 无。
    /// 返回：与固定来源一致的范围说明。
    var summary: String {
        switch self {
        case .directory:
            return "目录范围"
        case .projectReferences(let captures):
            return "项目面板 "
                + captures.map {
                    String($0.index + 1)
                }.joined(separator: "、")
        case .projects(_, _, let panels):
            return "项目面板 "
                + panels.map {
                    String($0 + 1)
                }.joined(separator: "、")
        }
    }

    /// 业务作用：替换确认使用真实来源名称，用户据此判断即将授予的文件修改范围。
    /// 参数说明: 无。
    /// 返回：目录或所选项目的替换标题。
    var replacementTitle: String {
        switch self {
        case .directory:
            return "文件中替换"
        case .projects, .projectReferences:
            return "所选项目中替换"
        }
    }

    /// 业务作用：仅目录范围执行递归枚举，项目范围只读取既有显式文件引用。
    /// 参数说明:
    /// - options: 当前递归与隐藏项选项。
    /// - matcher: 实际文件名和目录的过滤规则。
    /// - token: 本次读取的取消权限。
    /// 返回：完整目标清单及不能解释的项目引用，取消或目录超限终止计划。
    func targets(
        options: SearchOptions,
        matcher: FileFilters,
        token: CancellationToken
    ) throws -> (files: [URL], failures: [String]) {
        try token.check()
        switch self {
        case .directory(let root):
            let listing = try DirectoryTraversal.listing(
                under: root,
                limit: 100_000,
                recursive: options.recursive,
                includeHidden: options.includeHidden,
                fileFilter: {
                    matcher.accepts($0)
                },
                directoryFilter: {
                    matcher.acceptsDirectory($0, depth: $1)
                },
                permit: {
                    !token.isCancelled
                }
            )
            return (listing.files, listing.failures)
        case .projects(let files, let failures, _):
            return (files, failures)
        case .projectReferences:
            // 原始定义不含卷访问权，必须先经过本次范围的显式位置选择。
            throw NateError.message("项目引用尚未完成位置授权，文件未读取。")
        }
    }
}

struct FileSearchBufferSnapshot: Sendable {
    let url: URL
    let baseline: DiskBaseline?
    let snapshot: DocumentSnapshot
}

struct FileSearchPreparation: Sendable {
    let plans: [DirectoryPlan]
    let failures: [String]
    let unmapped: Int
    let readFiles: Int
}

enum FileSearchPlanning {
    /// 业务作用：在独立读取队列上固定目标、原字节基线和有界结果，所有文件共用命中与替换预算。
    /// 参数说明:
    /// - source: 用户已经授予本次读取权的完整目录或项目范围。
    /// - filters: 文件名包含与排除原文。
    /// - options: 已移除选区和方向限制的全文条件。
    /// - replacing: 是否准备逐文件替换意图。
    /// - opened: 原请求捕获的已打开文件及其正文快照。
    /// - access: 系统协调下的严格文件读取入口。
    /// - catalog: 当前严格代码页映射。
    /// - token: 独立队列的取消权限。
    /// 返回：完整预览及逐项失败；资源超限或取消不返回部分替换计划。
    static func prepare(
        source: FileSearchSource,
        filters: String,
        options: SearchOptions,
        replacing: Bool,
        opened: [FileSearchBufferSnapshot],
        access: CoordinatedFileAccess,
        catalog: LegacyCodecCatalog?,
        token: CancellationToken
    ) throws -> FileSearchPreparation {
        let matcher = FileFilters(filters)
        _ = try SearchEngine.find(
            in: DocumentSnapshot(id: UUID(), revision: 0, text: PieceTree()),
            options: options,
            permit: {
                !token.isCancelled
            }
        )
        var buffers: [Data: DocumentSnapshot] = [:]
        var buffersByFile: [String: DocumentSnapshot] = [:]
        var ambiguousFiles: Set<String> = []
        for captured in opened {
            try token.check()
            // 已有真实基线优先使用缓存身份；缺少基线的路径解析也不能阻塞主执行域。
            let key = Data(
                (captured.baseline?.resolvedPath ?? captured.url.resolvingSymlinksInPath().path).utf8
            )
            if buffers[key] == nil {
                buffers[key] = captured.snapshot
            }
            if let baseline = captured.baseline {
                let identity = "\(baseline.device):\(baseline.inode)"
                if let previous = buffersByFile[identity], previous.id != captured.snapshot.id {
                    ambiguousFiles.insert(identity)
                }
                buffersByFile[identity] = captured.snapshot
            }
        }
        let targets = try source.targets(options: options, matcher: matcher, token: token)
        var failures = targets.failures
        guard failures.count <= 10_000 else {
            throw NateError.message("未读取引用超过 10000 项，请缩小项目范围；未发布部分计划。")
        }
        var plans: [DirectoryPlan] = []
        var budget = DirectorySearchPlanBudget()
        var preview = SearchResultPreviewBuilder(permit: {
            !token.isCancelled
        })
        var identities: Set<String> = []
        var readFiles = 0
        for url in targets.files {
            try token.check()
            guard matcher.accepts(url.lastPathComponent) else {
                continue
            }
            do {
                let loaded = try access.load(
                    url,
                    catalog: catalog,
                    maximumBytes: DirectoryPlan.maximumSourceBytes,
                    permit: {
                        !token.isCancelled
                    }
                )
                let identity = "\(loaded.baseline.device):\(loaded.baseline.inode)"
                if !identities.insert(identity).inserted {
                    continue
                }
                readFiles += 1
                // 硬链接的路径次序不能把已打开正文降成磁盘目标，存在多个不同缓冲区时也不任意选择写入者。
                guard options.ignoreOpenBuffers && !replacing || !ambiguousFiles.contains(identity) else {
                    throw NateError.message("同一文件身份对应多个打开缓冲区，请先明确保留的正文。")
                }
                let original =
                    (!options.ignoreOpenBuffers || replacing)
                    ? (buffersByFile[identity] ?? buffers[Data(loaded.baseline.resolvedPath.utf8)]) : nil
                let snapshot = original ?? DocumentSnapshot(id: UUID(), revision: 0, text: loaded.tree)
                let result = try SearchEngine.find(
                    in: snapshot,
                    options: options,
                    permit: {
                        !token.isCancelled
                    }
                )
                if result.hits.isEmpty {
                    continue
                }
                try budget.reserveHits(result.hits.count)
                let edits =
                    replacing
                    ? try SearchEngine.replacementPlan(
                        result,
                        snapshot: snapshot,
                        permit: {
                            !token.isCancelled
                        }
                    ) : []
                try budget.reserveReplacements(
                    edits,
                    permit: {
                        !token.isCancelled
                    }
                )
                let prepared =
                    replacing && original != nil
                    ? try PreparedTransaction(
                        snapshot: snapshot,
                        edits: edits,
                        name: source.replacementTitle
                    ) : nil
                let rows =
                    replacing
                    ? [] : try preview.prepare(result.hits, text: snapshot.text, label: url.path)
                plans.append(
                    DirectoryPlan(
                        url: url,
                        baseline: loaded.baseline,
                        encoding: loaded.encoding,
                        documentID: original?.id,
                        revision: original?.revision,
                        hitCount: result.hits.count,
                        edits: original == nil ? edits : [],
                        prepared: prepared,
                        previews: rows
                    )
                )
            }
            catch {
                if error is CancellationError || error is SearchPreviewFailure
                    || error is DirectorySearchPlanFailure
                {
                    throw error
                }
                failures.append(url.path + "：" + error.localizedDescription)
                guard failures.count <= 10_000 else {
                    throw NateError.message("未读取文件超过 10000 项，请缩小范围。")
                }
            }
        }
        return FileSearchPreparation(
            plans: plans,
            failures: failures,
            unmapped: preview.unmappedCount,
            readFiles: readFiles
        )
    }
}
