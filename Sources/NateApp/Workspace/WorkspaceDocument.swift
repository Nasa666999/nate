import Foundation
import NateCore
import NateStorage

@MainActor
final class WorkspaceDocument {
    let buffer: DocumentBuffer
    var url: URL?
    var name: String
    var encoding: TextEncoding {
        TextEncoding.available.first {
            $0.codePage == buffer.format.codePage && $0.bom == buffer.format.bom
        }
            ?? TextEncoding(
                codePage: buffer.format.codePage,
                bom: buffer.format.bom,
                name: "CP\(buffer.format.codePage)"
            )
    }
    var savedEncoding = TextEncoding.utf8
    var baseline: DiskBaseline?
    var pendingOriginalPath: String?
    var pendingOriginalBaseline: DiskBaseline?
    var originalBindingTask: Task<Void, Never>?
    var originalBindingRequest = UUID()
    var savedText: PieceTree
    var language = "normal"
    var languageExplicit = false
    var pinned = false
    var targetGeneration: UInt64 = 0
    var bindingChange = false
    var closing = false
    var state = "临时文档 · 等待恢复保存"
    var failure: String?
    var conflict = false
    var saveTask: Task<Bool, Never>?
    var savePermit: CancellationToken?
    var recoveryReference: RecoveryReference?
    var recoveryRevision: UInt64?
    var recoveryError: String?
    var lastRecoveryMetadata = ""
    var lastSavedRevision: UInt64 = 0
    var dirtyHint = false
    var nextRetry = ContinuousClock.now
    var retryCount = 0
    var monitoring = false
    var readOnlyBeforeMonitoring = false
    var isDirty: Bool {
        dirtyHint || encoding != savedEncoding
    }
    var recoveryMetadataKey: String {
        let positions = buffer.selections.map {
            "\($0.anchor):\($0.head):\($0.virtualColumn)"
        }.joined(separator: ",")
        let bookmarks = buffer.bookmarks.sorted().map(String.init).joined(separator: ",")
        return
            "\(url?.path ?? pendingOriginalPath ?? "")|\(name)|\(encoding.codePage)|\(encoding.bom)|\(buffer.format.lineEnding.rawValue)|\(language)|\(buffer.isReadOnly)|\(baseline?.digest ?? pendingOriginalBaseline?.digest ?? "")|\(positions)|\(bookmarks)"
    }

    /// 业务作用：建立标签元数据，正文身份不随路径改变。
    /// 参数说明:
    /// - name: 显示名称。
    /// - text: 初始正文。
    /// - textTree: 后台已准备的正文，为空时由初始字符串构建。
    /// - id: 恢复文档稳定身份。
    /// - encoding: 初始字节编码。
    /// - lineEnding: 新插入换行的规则。
    /// 返回：跨视图共享的文件关联和保存状态。
    init(
        name: String,
        text: String = "",
        textTree: PieceTree? = nil,
        id: UUID = UUID(),
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf
    ) {
        self.name = name
        buffer = DocumentBuffer(
            text: textTree ?? PieceTree(text),
            id: id,
            format: DocumentFormat(codePage: encoding.codePage, bom: encoding.bom, lineEnding: lineEnding)
        )
        savedEncoding = encoding
        savedText = buffer.text
    }

    /// 业务作用：经过可表示性验证的编码参数与正文共用撤销历史。
    /// 参数说明:
    /// - encoding: 已完整验证的目标编码。
    /// 返回：单调修订与格式一次性发布，撤销会恢复旧参数。
    func setEncoding(_ encoding: TextEncoding) throws {
        var format = buffer.format
        format.codePage = encoding.codePage
        format.bom = encoding.bom
        try buffer.commit([], formatAfter: format, name: "转换编码")
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
            path: url?.path ?? pendingOriginalPath,
            encoding: encoding,
            baseline: baseline ?? pendingOriginalBaseline,
            language: language,
            selections: buffer.selections,
            bookmarks: buffer.bookmarks,
            readOnly: buffer.isReadOnly,
            lineEnding: buffer.format.lineEnding
        )
    }
}
