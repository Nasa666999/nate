import Foundation
import NateCore
import NateStorage
import NateSyntax

enum PathCompletionDirectory {
    static let maximumEntries = 20_000
    static let maximumCandidates = 200

    /// 业务作用：只枚举用户明确请求的一层，候选名称及排序受同一读取预算约束。
    /// 参数说明:
    /// - directory: 从当前文档实际目录解析的本地目标。
    /// - namePrefix: 用户正在输入的最后一个路径分量。
    /// - writtenParent: 候选中须保留的原始父路径拼写及分隔符。
    /// - entryLimit: 本次可检查的目录项数量上限。
    /// - check: 当前同步读取仍持有请求的执行资格。
    /// 返回：最多二百个当前范围的自然排序结果及范围受限标识；读取失败或取消时不发布。
    static func read(
        directory: URL,
        namePrefix: String,
        writtenParent: String,
        entryLimit: Int,
        check: () throws -> Void
    ) throws -> (candidates: [CompletionCandidate], limited: Bool) {
        guard (1...maximumEntries).contains(entryLimit) else {
            throw NateError.message("路径补全目录项预算无效。")
        }
        try FileStorage.validateFileURL(directory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))

        /// 业务作用：目录枚举、匹配排序和候选属性读取共用原请求的取消与时限。
        /// 参数说明: 无。
        /// 返回：当前继续具有读取资格；过期或取消时结束整次请求。
        func checkpoint() throws {
            try check()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("路径补全已超过五秒目录读取预算。")
            }
        }

        try checkpoint()
        let resolved = directory.resolvingSymlinksInPath()
        var failure: (any Error)?
        guard
            let entries = FileManager.default.enumerator(
                at: resolved,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    failure = error
                    return false
                }
            )
        else {
            throw NateError.message("无法枚举指定目录。")
        }
        let folded = namePrefix.lowercased()
        var scanned = 0
        var limited = false
        var matching: [URL] = []
        for case let url as URL in entries {
            try checkpoint()
            // 预算计算包含未命中的条目，稀疏前缀也不能展开整个大目录。
            guard scanned < entryLimit else {
                limited = true
                break
            }
            scanned += 1
            if url.lastPathComponent.lowercased().hasPrefix(folded) {
                matching.append(url)
            }
        }
        if let failure {
            throw failure
        }
        let sorted = try matching.sorted {
            try checkpoint()
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let candidates = try sorted.prefix(maximumCandidates).map { url in
            try checkpoint()
            let folder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return CompletionCandidate(
                text: writtenParent + url.lastPathComponent + (folder ? "/" : ""),
                detail: (folder ? "目录 · " : "文件 · ") + directory.path
            )
        }
        try checkpoint()
        return (candidates, limited || matching.count > maximumCandidates)
    }
}
