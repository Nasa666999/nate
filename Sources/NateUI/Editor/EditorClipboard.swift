import AppKit
import NateCore

extension EditorView {
    /// 业务作用：复制异步完整准备文本与形态，任何来源门禁失败都发生在清空剪贴板之前。
    /// 参数说明:
    /// - sender: 原生命令来源。
    /// 返回：启动当前视图复制；准备失败或过期保留原正文和剪贴板。
    @objc public func copy(_ sender: Any?) {
        startClipboardCopy(cutting: false)
    }

    /// 业务作用：剪切先准备复制与删除，再同步发布剪贴板和唯一正文事务。
    /// 参数说明:
    /// - sender: 原生命令来源。
    /// 返回：剪贴板写入成功后才删除；只读、过期和准备失败均不删除原文。
    @objc public func cut(_ sender: Any?) {
        startClipboardCopy(cutting: true)
    }

    /// 业务作用：普通粘贴优先读取明确形态，不把外部文本中的换行推测为矩形。
    /// 参数说明:
    /// - sender: 原生命令来源。
    /// 返回：后台准备完整事务；未知私有格式明确拒绝并可另选纯文本粘贴。
    @objc public func paste(_ sender: Any?) {
        startClipboardPaste(plainOnly: false)
    }

    /// 业务作用：用户明确选择后只读取系统普通文本，不继承私有形态。
    /// 参数说明:
    /// - sender: 原生命令来源。
    /// 返回：原样普通文本通过同一原子粘贴与权限门禁。
    @objc public func pasteAsPlainText(_ sender: Any?) {
        startClipboardPaste(plainOnly: true)
    }

    /// 业务作用：用户取消等待中的剪贴板动作，尚未发布的副作用全部失权。
    /// 参数说明: 无。
    /// 返回：停止准备且不消费撤销历史。
    public func cancelClipboardOperation() {
        clipboard.cancel()
    }

    /// 业务作用：从实际编辑焦点建立完整动作证据，候选没有确认前不切换到剪贴板写入。
    /// 参数说明:
    /// - modifying: 是否需要当前编辑权限。
    /// - boardCount: 需要绑定的系统剪贴板变化身份，宏和历史直接输入时为空。
    /// 返回：完整发布证据；焦点、候选、权限或选择不足时明确失败。
    func beginClipboardOperation(modifying: Bool, boardCount: Int?) throws -> ClipboardProof {
        try requireCurrentRectangleLayout()
        guard let window, window.isKeyWindow, window.firstResponder === self else {
            throw NateError.message("剪贴板动作需要实际正文编辑焦点。")
        }
        guard composition == nil else {
            throw NateError.message("请先确认或取消输入法候选，再执行剪贴板动作。")
        }
        guard
            !modifying
                || !document.isReadOnly && !document.isEditingSuspended && document.revision < UInt64.max
        else {
            throw NateError.message("当前文档不能提交剪贴板编辑。")
        }
        guard synchronizeDocumentSelectionState(), document.selectionState != nil else {
            throw NateError.message("剪贴板动作缺少完整选择证据。")
        }
        clipboard.cancel()
        onCommand?("clipboardBegan")
        return ClipboardProof(
            document: document,
            snapshot: document.snapshot,
            operation: clipboard.generation,
            selection: selectionGeneration,
            focus: focusGeneration,
            editing: document.editingAuthorityGeneration,
            font: font,
            wrapping: wrapLines,
            rtl: rtl,
            window: window,
            boardCount: boardCount,
            modifying: modifying
        )
    }

    /// 业务作用：读取和切除共享同一来源，全部内容及结果正文先就绪再触碰系统剪贴板。
    /// 参数说明:
    /// - cutting: 是否同时准备删除事务。
    /// - copyLine: 宏固定的整行选项，省略时使用当前视图设置。
    /// 返回：已启动动作的独立身份；失败为空且不发布部分内容。
    @discardableResult
    private func startClipboardCopy(cutting: Bool, copyLine: Bool? = nil) -> UUID? {
        do {
            let proof = try beginClipboardOperation(
                modifying: cutting,
                boardCount: NSPasteboard.general.changeCount
            )
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let projections = try rectangularCopyProjections()
            let targets = cutting && rectangularSelections != nil ? try rectangularInsertionTargets("") : nil
            let line = copyLine ?? copyLineWithoutSelection
            let snapshot = proof.snapshot
            clipboard.task = Task {
                [weak self] in
                guard let self else {
                    return
                }
                defer {
                    clipboard.finish(proof.operation)
                }
                do {
                    let result = try await clipboard.prepare {
                        let copied = try PreparedClipboardCopy(
                            snapshot: snapshot,
                            projections: projections,
                            copyLineWithoutSelection: line,
                            deadline: deadline
                        )
                        let cut =
                            cutting
                            ? try PreparedClipboardCut(
                                snapshot: snapshot,
                                copied: copied,
                                rectangularTargets: targets,
                                deadline: deadline
                            ).transaction : nil
                        return (copied, cut)
                    }
                    // 所有正文与形态先准备完成，复验后到剪切提交之间没有挂起点，不能跨到新选区。
                    guard proof.matches(self) else {
                        throw CancellationError()
                    }
                    let item = NSPasteboardItem()
                    guard item.setString(result.0.plainText, forType: .string),
                        item.setData(result.0.data, forType: ClipboardRuntime.type)
                    else {
                        throw NateError.message("无法准备完整系统剪贴板表示，原内容保留。")
                    }
                    let board = NSPasteboard.general
                    guard proof.matches(self) else {
                        throw CancellationError()
                    }
                    // 从这里到串行发布结束没有挂起；结果选择的正常同步不应取消本次已取得发布权的回调。
                    clipboard.finish(proof.operation)
                    board.clearContents()
                    guard board.writeObjects([item]) else {
                        throw NateError.message("系统剪贴板写入未成功，原文未删除。")
                    }
                    if let cut = result.1 {
                        let changed = try document.commit(cut)
                        refresh(reveal: true)
                        onSelection?()
                        if changed {
                            onChange?()
                        }
                    }
                    onClipboardCapture?(result.0.payload)
                    clipboard.succeeded = proof.operation
                    onStatus?(cutting ? "已剪切。" : "已复制。")
                    onClipboardCopy?(cutting, line)
                }
                catch is CancellationError {
                    onStatus?("剪贴板动作已取消或来源已改变，未提交旧结果。")
                }
                catch {
                    onStatus?(error.localizedDescription)
                }
            }
            return proof.operation
        }
        catch {
            onStatus?(error.localizedDescription)
            return nil
        }
    }

    /// 业务作用：宏复用原生复制与剪切的完整发布路径，等待实际成功，不能按任务启动推断已经写入或删除。
    /// 参数说明:
    /// - cutting: 是否在完整系统剪贴板写入后删除当前内容。
    /// - copyLineWithoutSelection: 录制时固定的无选区整行规则，不改变当前偏好。
    /// 返回：同一动作实际完成时为真；取消、来源改变、权限或系统写入失败时为假。
    public func copySelection(cutting: Bool, copyLineWithoutSelection: Bool) async -> Bool {
        guard !Task.isCancelled,
            let request = startClipboardCopy(cutting: cutting, copyLine: copyLineWithoutSelection),
            let task = clipboard.task
        else {
            return false
        }
        await withTaskCancellationHandler(
            operation: {
                await task.value
            },
            onCancel: {
                task.cancel()
            }
        )
        return !Task.isCancelled && clipboard.succeeded == request
    }
}
