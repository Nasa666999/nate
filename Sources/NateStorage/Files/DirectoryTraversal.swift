import Foundation
import NateCore

public enum DirectoryTraversal {
    /// 业务作用：列出有界普通文件，符号链接不递归以防止目录循环。
    /// 参数说明:
    /// - root: 用户明确选择的根目录。
    /// - filter: 已由搜索层解释的调用上下文说明，不参与存储过滤。
    /// - limit: 最大候选文件数。
    /// 返回：文件路径；无权限或超过范围时明确失败。
    public static func files(under root: URL, filter: String, limit: Int) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            throw NateError.message("无法读取所选目录。")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                files.append(url)
                guard files.count <= limit else {
                    throw NateError.message("候选文件超过 \(limit) 项，请缩小目录范围。")
                }
            }
        }
        return files.sorted {
            $0.path < $1.path
        }
    }
}
