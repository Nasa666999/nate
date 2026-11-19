import AppKit
import NateCore

public enum ClipboardSpecialPaste: Sendable {
    case htmlSource
    case rtfSource
    case binary
}

extension EditorView {
    /// 业务作用：特殊粘贴只接受用户明确选择的实际表示，不把普通文本的类型继承关系猜成二进制。
    /// 参数说明:
    /// - format: 明确选择的源码或二进制入口。
    /// 返回：原生编辑焦点、权限和实际类型均满足时可用；只检查类型，不读取正文载荷。
    public func specialPasteAvailable(_ format: ClipboardSpecialPaste) -> Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self, composition == nil,
            !document.isReadOnly, !document.isEditingSuspended, document.revision < UInt64.max,
            !hasStaleRectangleLayout, viewSelectionState != nil,
            selectionStateRevision == document.revision,
            format == .binary || clipboardMarkupDecoder != nil
        else {
            return false
        }
        return specialPasteType(format, board: .general) != nil
    }

    /// 业务作用：明确源码和二进制入口共用完整原子粘贴，解码失败或来源往返不改写原正文。
    /// 参数说明:
    /// - format: 本次明确选择的表示，HTML 和 RTF 只插入源码文本。
    /// 返回：启动有界解码与唯一正文事务；不渲染富文本、不加载外部资源、不改变文件格式。
    public func pasteSpecial(_ format: ClipboardSpecialPaste) {
        do {
            let board = NSPasteboard.general
            let proof = try beginClipboardOperation(modifying: true, boardCount: board.changeCount)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            guard let type = specialPasteType(format, board: board), let data = board.data(forType: type)
            else {
                throw NateError.message("剪贴板没有本次明确选择的完整表示，原正文保持不变。")
            }
            let encoded = type == ClipboardRuntime.type
            let limit = encoded ? ClipboardLimits.encodedBytes : ClipboardLimits.contentBytes
            guard data.count <= limit else {
                throw NateError.message("特殊剪贴板表示超过容量限制，原正文保持不变。")
            }
            let decoder = clipboardMarkupDecoder
            // 源码和二进制入口保持原始换行，不借全局普通粘贴偏好改写本次完整载荷。
            clipboard.task = Task {
                [weak self] in
                guard let self else {
                    return
                }
                defer {
                    clipboard.finish(proof.operation)
                }
                do {
                    let content = try await clipboard.prepare {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else {
                            throw CancellationError()
                        }
                        let payload: ClipboardPayload
                        if encoded {
                            payload = try ClipboardPayload.decode(data, deadline: deadline)
                        }
                        else {
                            let text: String
                            switch format {
                            case .binary:
                                guard
                                    let value = String(
                                        data: data,
                                        encoding: .utf8
                                    )
                                else {
                                    throw NateError.message("二进制载荷不是完整 UTF-8 文本，未猜测编码或截断 NUL。")
                                }
                                text = value
                            case .htmlSource, .rtfSource:
                                guard let decoder else {
                                    throw NateError.message("源码剪贴板解码尚未配置，原正文保持不变。")
                                }
                                text = try decoder(data, format == .htmlSource ? .html : .rtf, deadline)
                            }
                            payload = try ClipboardPayload(
                                fragments: [
                                    ClipboardFragment(
                                        text: text,
                                        documentOrder: 0
                                    )
                                ],
                                primaryIndex: 0
                            )
                        }
                        return try ClipboardPasteContent(
                            payload: payload,
                            deadline: deadline
                        )
                    }
                    _ = try await applyClipboardContent(
                        content,
                        proof: proof,
                        deadline: deadline,
                        adapting: false
                    )
                }
                catch is CancellationError {
                    onStatus?("特殊粘贴已取消或来源已改变，未提交旧结果。")
                }
                catch {
                    onStatus?(error.localizedDescription)
                }
            }
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：精确类型匹配区分原生源码、完整形态与外部原始数据，普通文本不取得二进制资格。
    /// 参数说明:
    /// - format: 当前明确选择的格式。
    /// - board: 本次原生剪贴板。
    /// 返回：实际登记的唯一首选类型，缺失时为空；不请求类型转换或读取数据。
    private func specialPasteType(_ format: ClipboardSpecialPaste, board: NSPasteboard) -> NSPasteboard
        .PasteboardType?
    {
        let types = board.types ?? []
        switch format {
        case .htmlSource: return types.contains(.html) ? .html : nil
        case .rtfSource: return types.contains(.rtf) ? .rtf : nil
        case .binary:
            if types.contains(ClipboardRuntime.type) {
                return ClipboardRuntime.type
            }
            let raw = NSPasteboard.PasteboardType("public.data")
            return types.contains(raw) ? raw : nil
        }
    }
}
