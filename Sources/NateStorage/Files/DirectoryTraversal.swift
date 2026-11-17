import Foundation
import NateCore

public struct DirectoryListing: Sendable {
    public var files: [URL]
    public var failures: [String]
}

public enum DirectoryTraversal {
    /// 业务作用：列出有界普通文件，不递归符号链接和应用包，权限失败分别反馈。
    /// 参数说明:
    /// - root: 用户明确选择的根目录。
    /// - limit: 最大匹配文件数。
    /// - recursive: 是否进入子目录。
    /// - includeHidden: 是否包含隐藏项。
    /// - fileFilter: 注入的文件名匹配规则。
    /// - directoryFilter: 目录名及相对层级规则，第一层为零。
    /// - permit: 继续遍历的请求权限。
    /// 返回：匹配文件和实际未读取清单，超限和取消明确失败。
    public static func listing(
        under root: URL,
        limit: Int,
        recursive: Bool = true,
        includeHidden: Bool = false,
        fileFilter: @Sendable (String) -> Bool = {
            _ in true
        },
        directoryFilter: @Sendable (String, Int) -> Bool = {
            _,
            _ in true
        },
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DirectoryListing {
        // 创建枚举器本身也可能访问外部目录，失权请求必须在建立遍历之前停止。
        guard permit() else {
            throw CancellationError()
        }
        try FileStorage.validateFileURL(root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var failures: [String] = []
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: {
                    url,
                    error in
                    failures.append(url.path + "：" + error.localizedDescription)
                    return true
                }
            )
        else {
            throw NateError.message("无法读取所选目录。")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard permit() else {
                throw CancellationError()
            }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true {
                    let depth = max(0, url.pathComponents.count - root.pathComponents.count - 1)
                    if !recursive || !directoryFilter(url.lastPathComponent, depth) {
                        enumerator.skipDescendants()
                    }
                }
                else if values.isRegularFile == true && fileFilter(url.lastPathComponent) {
                    files.append(url)
                    guard files.count <= limit else {
                        throw NateError.message("匹配文件超过 \(limit) 项，请缩小范围。")
                    }
                }
            }
            catch let error as NateError {
                throw error
            }
            catch {
                failures.append(url.path + "：" + error.localizedDescription)
            }
        }
        return DirectoryListing(
            files: files.sorted {
                $0.path < $1.path
            },
            failures: failures
        )
    }

    /// 业务作用：目录工作区要求完整清单，任何未读取路径都明确阻止完整成功结论。
    /// 参数说明:
    /// - root: 目录根。
    /// - limit: 文件数预算。
    /// 返回：完整文件列表；部分失败时保留具体路径说明。
    public static func files(under root: URL, limit: Int) throws -> [URL] {
        let result = try listing(under: root, limit: limit)
        guard result.failures.isEmpty else {
            throw NateError.message("目录部分不可读取：\n" + result.failures.joined(separator: "\n"))
        }
        return result.files
    }
}
