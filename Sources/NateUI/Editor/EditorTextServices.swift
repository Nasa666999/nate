import AppKit
import NateCore

extension EditorView {
    static let maximumSystemTextBytes = 8 * 1024 * 1024

    /// 业务作用：系统文本写入由实际键盘视图持有，窗口外或等待确认的候选不能被覆盖。
    /// 参数说明: 无。
    /// 返回：当前视图仍拥有键盘焦点且正文没有预编辑或编辑保护时为真。
    var ownsSystemTextTarget: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
            && !hasMarkedText() && !document.isEditingSuspended
    }

    /// 业务作用：系统文本服务使用单个明确的可提交范围，不在矩形或多光标中猜测返回目标。
    /// 参数说明: 无。
    /// 返回：当前选区的严格 UTF-8 字节范围；视图失效、虚拟列或多选时为空。
    var systemTextSelection: ByteRange? {
        guard selectionStateRevision == document.revision, let state = viewSelectionState,
            case .stream = state.shape, state.entries.count == 1, state.primary.selection.virtualColumn == 0
        else {
            return nil
        }
        return state.primary.selection.range
    }

    /// 业务作用：AppKit 服务只向当前实际正文提供明确支持的纯文本方向。
    /// 参数说明:
    /// - sendType: 服务读取选区所需的剪贴板类型，为空表示不读取。
    /// - returnType: 可能用来替换选区的类型，为空表示不写入。
    /// 返回：符合输入状态、选区、权限和容量的独立请求对象；其余交还原生响应链。
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if ownsSystemTextTarget, sendType != nil || returnType != nil,
            sendType == nil || sendType == .string, returnType == nil || returnType == .string,
            returnType == nil || !document.isReadOnly,
            let range = systemTextSelection, sendType == nil || !range.isEmpty,
            range.count <= Self.maximumSystemTextBytes
        {
            return EditorTextServiceRequest(
                editor: self,
                range: range,
                sendsText: sendType != nil,
                receivesText: returnType != nil
            )
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// 业务作用：将通过原生系统入口确认的显式选区替换送入唯一正文和撤销事务。
    /// 参数说明:
    /// - value: 已完整解码的纯文本结果。
    /// - range: 调用方已复验的当前实际选择范围。
    /// - name: 可在撤销历史中识别的操作名称。
    /// 返回：正文安全提交或相同文本收束选择时为真；权限、容量或范围失败时保留原输入。
    @discardableResult
    func replaceSystemTextSelection(_ value: String, range: ByteRange, name: String) -> Bool {
        // 先复验原视图和完整范围，系统迟到的返回值不得写入另一光标或覆盖输入法候选。
        guard ownsSystemTextTarget, !document.isReadOnly, systemTextSelection == range,
            value.utf8.prefix(Self.maximumSystemTextBytes + 1).count <= Self.maximumSystemTextBytes,
            synchronizeDocumentSelectionState()
        else {
            return false
        }
        do {
            let changed = try document.insert(value, name: name, replacementRange: range)
            refresh(reveal: true)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }
}

@MainActor
final class EditorTextServiceRequest: NSObject, @preconcurrency NSServicesMenuRequestor {
    private weak var editor: EditorView?
    private weak var document: DocumentBuffer?
    private let revision: UInt64
    private let selection: UUID
    private let focus: UUID
    private let authority: UUID
    private let range: ByteRange
    private let sendsText: Bool
    private let receivesText: Bool
    private var supplied = false
    private var consumed = false

    /// 业务作用：记录系统本次服务所获得的窗口、文档、范围和方向资格。
    /// 参数说明:
    /// - editor: 真实的键盘来源视图。
    /// - range: 已校验的原始范围。
    /// - sendsText: 服务是否请求发送原始选区。
    /// - receivesText: 服务是否允许写回纯文本。
    /// 返回：只持有元数据和弱来源，请求本身不读取或改写正文。
    init(editor: EditorView, range: ByteRange, sendsText: Bool, receivesText: Bool) {
        self.editor = editor
        document = editor.document
        revision = editor.document.revision
        selection = editor.selectionGeneration
        focus = editor.focusGeneration
        authority = editor.document.editingAuthorityGeneration
        self.range = range
        self.sendsText = sendsText
        self.receivesText = receivesText
        super.init()
    }

    /// 业务作用：复验系统服务期间原视图没有切换正文、选择或编辑资格。
    /// 参数说明: 无。
    /// 返回：请求原窗口与范围仍有资格时返回同一编辑视图，否则为空。
    private func currentEditor() -> EditorView? {
        guard let editor, let document, editor.ownsSystemTextTarget, editor.document === document,
            document.revision == revision, editor.selectionGeneration == selection,
            editor.focusGeneration == focus,
            document.editingAuthorityGeneration == authority, editor.systemTextSelection == range, !consumed
        else {
            return nil
        }
        return editor
    }

    /// 业务作用：将用户通过系统服务明确选择的纯文本写入系统提供的专用剪贴板。
    /// 参数说明:
    /// - pasteboard: AppKit 提供给本次交互的剪贴板。
    /// - types: 本次服务实际请求的类型集合。
    /// 返回：原视图复验成功并成功提供完整文本时为真；不使用应用通用剪贴板历史。
    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard sendsText, types.contains(.string), let editor = currentEditor() else {
            return false
        }
        let bytes = Data(editor.document.text.bytes(in: range))
        pasteboard.clearContents()
        // 纯文本类型携带原始 UTF-8，避免 NSString 路径把前导 U+FEFF 当成传输标记。
        supplied = pasteboard.setData(bytes, forType: .string)
        return supplied
    }

    /// 业务作用：系统返回文本只能使用同一请求一次，失败不会改动原正文或选择。
    /// 参数说明:
    /// - pasteboard: AppKit 保存本次服务结果的指定剪贴板。
    /// 返回：完整 UTF-8 返回文本及原选择都合法且事务成功时为真。
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard receivesText, !sendsText || supplied, let editor = currentEditor(), !editor.document.isReadOnly,
            let data = pasteboard.data(forType: .string), data.count <= EditorView.maximumSystemTextBytes,
            let value = UTF8Text.decode(data)
        else {
            return false
        }
        // 先收回本次应用资格，再进入编辑及界面回调，重入时不能重复替换已提交结果。
        consumed = true
        return editor.replaceSystemTextSelection(value, range: range, name: "系统文本服务")
    }
}
