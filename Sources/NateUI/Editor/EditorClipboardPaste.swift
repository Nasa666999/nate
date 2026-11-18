import AppKit
import NateCore

private struct LegacyClipboardFragments: Decodable {
    let pieces: [String]

    /// 业务作用：旧格式在展开字符串对象之前先限制真实片段数，不能让小片段数组耗尽内存。
    /// 参数说明:
    /// - decoder: 已受原始字节容量限制的旧格式解码器。
    /// 返回：最多十万项且实际文字合计不超过 64 MiB 的完整数组。
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard
            container.count.map({
                $0 <= ClipboardLimits.fragments
            }) ?? true
        else {
            throw NateError.message("旧剪贴板片段超过十万项。")
        }
        var values: [String] = []
        var bytes = 0
        while !container.isAtEnd {
            try Task.checkCancellation()
            guard values.count < ClipboardLimits.fragments else {
                throw NateError.message("旧剪贴板片段超过十万项。")
            }
            let value = try container.decode(String.self)
            guard value.utf8.count <= ClipboardLimits.contentBytes - bytes else {
                throw NateError.message("旧剪贴板实际文字超过 64 MiB。")
            }
            values.append(value)
            bytes += value.utf8.count
        }
        pieces = values
    }
}

private enum ClipboardRead: Sendable {
    case payload(Data)
    case legacy(Data)
    case plain(Data)

    /// 业务作用：系统表示在后台转换为唯一完整载荷，非法私有格式不静默降级。
    /// 参数说明:
    /// - deadline: 原动作从读取开始的共同截止。
    /// 返回：保留原始 UTF-8 的完整载荷；未知格式、无效 UTF-8 或超量时失败。
    func decode(deadline: ContinuousClock.Instant) throws -> ClipboardPayload {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw CancellationError()
        }
        switch self {
        case .payload(let data):
            return try ClipboardPayload.decode(data, deadline: deadline)
        case .legacy(let data):
            let pieces = try JSONDecoder().decode(LegacyClipboardFragments.self, from: data).pieces
            guard !pieces.isEmpty, pieces.count <= ClipboardLimits.fragments else {
                throw NateError.message("旧剪贴板片段数量无效，请选择纯文本粘贴。")
            }
            return try ClipboardPayload(
                fragments: pieces.enumerated().map {
                    try ClipboardFragment(text: $0.element, documentOrder: $0.offset)
                },
                primaryIndex: 0
            )
        case .plain(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw NateError.message("剪贴板普通文本不是完整 UTF-8，原文保持不变。")
            }
            return try ClipboardPayload(
                fragments: [ClipboardFragment(text: text, documentOrder: 0)],
                primaryIndex: 0
            )
        }
    }
}

extension EditorView {
    /// 业务作用：用户主动粘贴时读取单一明确表示，不为历史持续监视其它应用剪贴板。
    /// 参数说明:
    /// - plainOnly: 是否明确只使用系统普通文本。
    /// 返回：启动完整原子粘贴；私有表示无效时提示使用纯文本入口，不自动猜测形态。
    func startClipboardPaste(plainOnly: Bool) {
        do {
            let proof = try beginClipboardOperation(
                modifying: true,
                boardCount: NSPasteboard.general.changeCount
            )
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let board = NSPasteboard.general
            let type: NSPasteboard.PasteboardType
            if !plainOnly, board.availableType(from: [ClipboardRuntime.type]) != nil {
                type = ClipboardRuntime.type
            }
            else if !plainOnly, board.availableType(from: [ClipboardRuntime.legacyType]) != nil {
                type = ClipboardRuntime.legacyType
            }
            else {
                type = .string
            }
            guard let data = board.data(forType: type) else {
                throw NateError.message("剪贴板没有可读取的完整文本。")
            }
            let limit = type == .string ? ClipboardLimits.contentBytes : ClipboardLimits.encodedBytes
            guard data.count <= limit else {
                throw NateError.message("剪贴板表示超过容量限制，原正文保持不变。")
            }
            let read: ClipboardRead =
                type == ClipboardRuntime.type
                ? .payload(data) : type == ClipboardRuntime.legacyType ? .legacy(data) : .plain(data)
            let ending = adaptClipboardLineEndings ? document.format.lineEnding : nil
            let adapt = adaptClipboardLineEndings
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
                        try ClipboardPasteContent(
                            payload: read.decode(deadline: deadline),
                            adaptingTo: ending,
                            deadline: deadline
                        )
                    }
                    _ = try await applyClipboardContent(
                        content,
                        proof: proof,
                        deadline: deadline,
                        adapting: adapt
                    )
                }
                catch is CancellationError {
                    onStatus?("粘贴已取消或来源已改变，未提交旧结果。")
                }
                catch {
                    onStatus?(error.localizedDescription + " 可明确选择“粘贴为纯文本”读取普通表示。")
                }
            }
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：宏和历史直接复用真实载荷，等待实际事务成功再继续，不改写系统剪贴板。
    /// 参数说明:
    /// - payload: 用户明确选择的完整历史或宏内容。
    /// - adaptLineEndings: 是否仅对本次插入内容适配当前文档换行。
    /// 返回：实际完成时为真；权限、布局、取消或来源失效时为假。
    public func pastePayload(_ payload: ClipboardPayload, adaptLineEndings: Bool = false) async -> Bool {
        do {
            let proof = try beginClipboardOperation(modifying: true, boardCount: nil)
            defer {
                clipboard.finish(proof.operation)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let ending = adaptLineEndings ? document.format.lineEnding : nil
            let content = try await clipboard.prepare {
                try ClipboardPasteContent(payload: payload, adaptingTo: ending, deadline: deadline)
            }
            return try await applyClipboardContent(
                content,
                proof: proof,
                deadline: deadline,
                adapting: adaptLineEndings
            )
        }
        catch is CancellationError {
            onStatus?("粘贴已取消或来源已改变，未提交旧结果。")
        }
        catch {
            onStatus?(error.localizedDescription)
        }
        return false
    }

    /// 业务作用：解码、原生列布局和后台正文构建之间分别复验，最后只发布一个完整事务。
    /// 参数说明:
    /// - content: 已完整准备的实际内容。
    /// - proof: 原实例、选择、焦点与剪贴板身份。
    /// - deadline: 所有阶段共同截止。
    /// - adapting: 本次输入实际使用的换行适配选项。
    /// 返回：事务提交成功后为真，包含相同字节仅更新选择的成功；失败不发布正文。
    private func applyClipboardContent(
        _ content: ClipboardPasteContent,
        proof: ClipboardProof,
        deadline: ContinuousClock.Instant,
        adapting: Bool
    ) async throws -> Bool {
        guard proof.matches(self) else {
            throw CancellationError()
        }
        let layout = try clipboardBlockLayout(content, deadline: deadline)
        guard proof.matches(self) else {
            throw CancellationError()
        }
        let snapshot = proof.snapshot
        let transaction = try await clipboard.prepare {
            if let layout {
                return try PreparedClipboardBlock(
                    snapshot: snapshot,
                    content: content,
                    layout: layout,
                    deadline: deadline
                ).transaction
            }
            return try PreparedClipboardPaste(snapshot: snapshot, content: content, deadline: deadline)
                .transaction
        }
        // 复验之后到提交之间没有挂起；原生选择与唯一正文在同一串行执行域内一起发布。
        guard proof.matches(self), ContinuousClock.now < deadline else {
            throw CancellationError()
        }
        // 提交后的选择更新会撤销旧准备身份，先释放计算句柄，避免成功动作取消自己的历史记录。
        clipboard.finish(proof.operation)
        let changed = try document.commit(transaction)
        refresh(reveal: true)
        onSelection?()
        if changed {
            onChange?()
        }
        onClipboardCapture?(content.payload)
        onClipboardPaste?(content.payload, adapting)
        onStatus?("已粘贴。")
        return true
    }
}
