import Foundation
import NateCore
import NateStorage

@MainActor
final class WorkspaceDocument {
    let buffer: DocumentBuffer
    var url: URL?
    var name: String
    var encoding = TextEncoding.utf8
    var savedEncoding = TextEncoding.utf8
    var baseline: DiskBaseline?
    var savedText: PieceTree
    var language = "normal"
    var languageExplicit = false
    var pinned = false
    var targetGeneration: UInt64 = 0
    var state = "临时文档 · 等待恢复保存"
    var failure: String?
    var conflict = false
    var saveTask: Task<Bool, Never>?
    var recoveryReference: RecoveryReference?
    var recoveryRevision: UInt64?
    var recoveryError: String?
    var lastRecoveryMetadata = ""
    var lastSavedRevision: UInt64 = 0
    var dirtyHint = false
    var nextRetry = ContinuousClock.now
    var retryCount = 0
    var monitoring = false
    var isDirty: Bool {
        dirtyHint || encoding != savedEncoding
    }

    /// 业务作用：建立标签元数据，正文身份不随路径改变。
    /// 参数说明:
    /// - name: 显示名称。
    /// - text: 初始正文。
    /// - id: 恢复文档稳定身份。
    /// 返回：跨视图共享的文件关联和保存状态。
    init(name: String, text: String = "", id: UUID = UUID()) {
        self.name = name
        buffer = DocumentBuffer(text: text, id: id)
        savedText = buffer.text
    }

    /// 业务作用：在保存周期精确判断字节差异，而不是每次按键全文比较。
    /// 参数说明: 无。
    /// 返回：更新真实脏状态，保存中的相反快照仍由完成回调重新判断。
    func evaluateDirty() {
        dirtyHint = encoding != savedEncoding || !buffer.text.byteEqual(to: savedText)
    }

    /// 业务作用：生成含正文、原目标和视图状态的独立恢复记录。
    /// 参数说明: 无。
    /// 返回：不会把恢复成功误认为原文件成功的快照。
    func recoveryDocument() -> RecoveryDocument {
        RecoveryDocument(
            id: buffer.id,
            revision: buffer.revision,
            name: name,
            text: "",
            path: url?.path,
            encoding: encoding,
            baseline: baseline,
            language: language,
            selections: buffer.selections,
            bookmarks: buffer.bookmarks,
            readOnly: buffer.isReadOnly
        )
    }
}
