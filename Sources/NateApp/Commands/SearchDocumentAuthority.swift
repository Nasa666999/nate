import Foundation
import NateCore

@MainActor
final class SearchDocumentAuthority {
    weak var document: WorkspaceDocument?
    let revision: UInt64
    let targetGeneration: UInt64
    let url: URL?

    /// 业务作用：固定搜索所属的真实文档生命周期，关闭后不继续持有正文或把稳定 UUID 当成新实例的权限。
    /// 参数说明:
    /// - document: 计划开始时仍在工作区中的文档。
    /// 返回：弱文档证据，以及当时的正文修订和文件绑定状态。
    init(_ document: WorkspaceDocument) {
        self.document = document
        revision = document.buffer.revision
        targetGeneration = document.targetGeneration
        url = document.url
    }

    /// 业务作用：发布前复验原文档仍然存活且未进入关闭或文件重绑定过程。
    /// 参数说明:
    /// - candidate: 当前工作区中找到的文档。
    /// - requireTarget: 目录动作还需原文件绑定和路径保持一致。
    /// 返回：对象、修订和适用的文件绑定证据全部一致时才允许继续。
    func matches(_ candidate: WorkspaceDocument, requireTarget: Bool = false) -> Bool {
        document === candidate && revision == candidate.buffer.revision && !candidate.closing
            && (!requireTarget
                || !candidate.bindingChange && targetGeneration == candidate.targetGeneration
                    && url == candidate.url)
    }
}
