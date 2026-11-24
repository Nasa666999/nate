import Foundation
import NateStorage

extension WorkspaceDocument {
    /// 业务作用：已经取得原文件资格的标签同时占有其真实路径和文件身份。
    /// 参数说明:
    /// - url: 调用方准备使用的原文件 URL。
    /// - path: 已解析的实际路径，保留文件名的原字节。
    /// - candidate: 新读取到的物理证据，准备创建的路径可以没有证据。
    /// 返回：路径相同或确认为同一个物理文件时为真，未获资格的恢复副本不占有原路径。
    func matchesBoundFile(_ url: URL, path: String, baseline candidate: DiskBaseline?) -> Bool {
        guard let bound = self.url else {
            return false
        }
        if let baseline,
            baseline.resolvedPath.utf8.elementsEqual(path.utf8)
                || candidate.map({ baseline.sharesFileIdentity(with: $0) }) == true
        {
            return true
        }
        return bound.standardizedFileURL.path.utf8.elementsEqual(url.standardizedFileURL.path.utf8)
    }
}

extension ApplicationController {
    /// 业务作用：打开、恢复及明确换目标均由同一工作区索引识别原文件持有者。
    /// 参数说明:
    /// - url: 当前文件动作原 URL。
    /// - path: 解析后的实际路径。
    /// - baseline: 实际文件身份，目标未创建时为空。
    /// - excluded: 需要排除的发起文档。
    /// 返回：仍登记并持有同一文件的规范文档，关闭中的标签仍须完成释放。
    func boundWorkspaceDocument(
        for url: URL,
        path: String,
        baseline: DiskBaseline?,
        excluding excluded: WorkspaceDocument? = nil
    ) -> WorkspaceDocument? {
        documents.first { $0 !== excluded && $0.matchesBoundFile(url, path: path, baseline: baseline) }
    }
}
