import Foundation
import NateCore
import NateStorage

struct RecoveryWorkspaceState: Sendable, Equatable {
    let documentIDs: [UUID]
    let activeID: UUID?
}

enum EditingSuspensionReason: Hashable {
    case documentClosing
    case applicationTermination
    case monitoringPreparation
}

@MainActor
final class WorkspaceDocument {
    private var editingSuspensions: Set<EditingSuspensionReason> = []
    /// 业务作用：冻结输入时显示仍持有保护的用户操作，不能让等待表现成无反馈的只读状态。
    /// 参数说明: 无。
    /// 返回：按退出、关闭、监视准备的顺序显示当前原因；没有暂停时为空。
    var editingSuspensionStatus: String? {
        if editingSuspensions.contains(.applicationTermination) {
            return "正在确认退出"
        }
        if editingSuspensions.contains(.documentClosing) {
            return "正在确认关闭"
        }
        if editingSuspensions.contains(.monitoringPreparation) {
            return "保存后进入监视"
        }
        return nil
    }
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
    var saveOperation: FileOperationRequest?
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
        var metadata = recoveryDocument()
        metadata.selections = []
        metadata.selectionState = nil
        return metadata.metadataKey + ":" + buffer.selectionGeneration.uuidString
    }

    /// 业务作用：建立标签元数据，正文身份不随路径改变。
    /// 参数说明:
    /// - name: 显示名称。
    /// - text: 初始正文。
    /// - textTree: 后台已准备的正文，为空时由初始字符串构建。
    /// - id: 恢复文档稳定身份。
    /// - encoding: 初始字节编码。
    /// - lineEnding: 新插入换行的规则。
    /// - revision: 自动恢复同一文档身份时沿用的已确认修订。
    /// 返回：跨视图共享的文件关联和保存状态。
    init(
        name: String,
        text: String = "",
        textTree: PieceTree? = nil,
        id: UUID = UUID(),
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        revision: UInt64 = 0
    ) {
        self.name = name
        buffer = DocumentBuffer(
            text: textTree ?? PieceTree(text),
            id: id,
            format: DocumentFormat(codePage: encoding.codePage, bom: encoding.bom, lineEnding: lineEnding),
            revision: revision
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

    /// 业务作用：关闭、退出和监视分别持有编辑暂停，任一流程结束都不能解除其它流程的保护。
    /// 参数说明:
    /// - reason: 当前流程持有的暂停原因。
    /// - active: 是否仍持有本流程的保护。
    /// 返回：内核只在全部暂停原因释放后重新接受正文事务，独立只读状态保持原语义。
    func setEditingSuspension(_ reason: EditingSuspensionReason, active: Bool) {
        if active {
            // 在异步文件等待之前发布保护，正文事务不能观察到尚未冻结的中间窗口。
            editingSuspensions.insert(reason)
        }
        else {
            // 只释放本流程的原因，取消退出不能提前解除仍在进行的关闭或监视准备。
            editingSuspensions.remove(reason)
        }
        buffer.isEditingSuspended = !editingSuspensions.isEmpty
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
            lineEnding: buffer.format.lineEnding,
            pinned: pinned,
            selectionState: buffer.selectionState
        )
    }

    /// 业务作用：恢复完整选择时保留全部稳定身份和形态，只有旧式记录才按合法几何重建。
    /// 参数说明:
    /// - record: 已与同一正文完成存储校验的恢复元数据。
    /// 返回：完整状态原样安装；旧记录至少建立原点光标，非法完整状态直接失败且不降级。
    func restoreSelections(from record: RecoveryDocument) throws {
        try restoreSelections(record.selectionState, legacySelections: record.selections)
    }

    /// 业务作用：恢复副本与命名会话使用同一选择入口，旧式虚拟光标只在真实行尾继续存在。
    /// 参数说明:
    /// - state: 存在时必须完整安装的稳定选择。
    /// - legacySelections: 仅没有完整归档时使用的旧几何。
    /// 返回：安装原完整状态或合法旧几何；非法完整状态失败且不丢弃其中部分身份。
    func restoreSelections(_ state: SelectionState?, legacySelections: [TextSelection]) throws {
        if let state {
            try buffer.setSelectionState(state)
        }
        else {
            let values = legacySelections.filter {
                value in
                guard buffer.text.isBoundary(value.anchor), buffer.text.isBoundary(value.head),
                    (0...1_000_000).contains(value.virtualColumn)
                else {
                    return false
                }
                let body = buffer.text.lineRange(buffer.text.lineNumber(at: value.head), includeEnding: false)
                return value.virtualColumn == 0 || value.range.isEmpty && value.head == body.upper
            }
            try buffer.setSelectionState(
                SelectionState(selections: values.isEmpty ? [TextSelection(anchor: 0, head: 0)] : values)
            )
        }
    }
}
