import AppKit
import NateCore

@MainActor
final class EditorWideTabLayout {
    struct Key: Hashable, Sendable {
        let documentID: UUID
        let revision: UInt64
        let range: ByteRange
        let tabGeneration: UUID
    }

    struct Entry: Sendable {
        let columns: ASCIITabColumns?
        let han: PlainHanLine?
        let status: String?
    }

    struct Reveal {
        let key: Key
        let selection: UUID
        let focus: UUID
        let viewport: NSPoint
    }

    static let measuring = "正在测量超长逻辑行的可见范围。"
    var entries: [Key: Entry] = [:]
    var task: Task<Void, Never>?
    var pendingReveal: Reveal?

    /// 业务作用：变化后的视图不能沿旧正文或旧列宽使用延迟测量，只在实际任务返回后释放唯一任务位。
    /// 参数说明: 无。
    /// 返回：旧缓存及导航意图失效，仍在运行的测量收到取消。
    func reset() {
        pendingReveal = nil
        entries.removeAll()
        task?.cancel()
    }
}

extension EditorView {
    /// 业务作用：有限长行窗口只接受对应实际文档及语言设置的完整原文证据。
    /// 参数说明:
    /// - snapshot: 当前布局请求的固定正文。
    /// - range: 当前真实逻辑行的完整原字节范围。
    /// 返回：已确认的索引、测量中的明确说明或原生回退状态，不在主线程顺序测量超长正文。
    func wideTabPreparation(snapshot: DocumentSnapshot, range: ByteRange) -> EditorWideTabLayout.Entry {
        guard !wrapLines, !rtl, composition == nil,
            range.count > EditorNativeLayoutPolicy.maximumParagraphBytes,
            snapshot.text.byteCount <= EditorNativeLayoutPolicy.maximumDocumentBytes,
            !snapshot.text.isPrintableASCII(in: range)
        else {
            return EditorWideTabLayout.Entry(columns: nil, han: nil, status: nil)
        }
        let key = wideTabKey(range)
        if let entry = wideTabLayout.entries[key] {
            return entry
        }
        guard wideTabLayout.entries.count < ASCIITabColumns.maximumLineProjections else {
            return EditorWideTabLayout.Entry(columns: nil, han: nil, status: nil)
        }
        if wideTabLayout.task == nil {
            prepareWideLine(snapshot: snapshot, key: key, width: tabSettings.width)
        }
        return EditorWideTabLayout.Entry(columns: nil, han: nil, status: EditorWideTabLayout.measuring)
    }

    /// 业务作用：为跨线程测量和实际导航固定同一正文与视觉任务代次。
    /// 参数说明:
    /// - range: 请求的完整逻辑行原文范围。
    /// 返回：正文、修订、行范围和 Tab 代次共同构成的来源身份。
    func wideTabKey(_ range: ByteRange) -> EditorWideTabLayout.Key {
        EditorWideTabLayout.Key(
            documentID: document.id,
            revision: document.revision,
            range: range,
            tabGeneration: tabSettingsGeneration
        )
    }

    /// 业务作用：把超长行的原字节测量交给有限后台任务，发布前重新确认实际视图与行来源。
    /// 参数说明:
    /// - snapshot: 当前逻辑行所属的不可变正文。
    /// - key: 测量开始时固定的视图布局来源。
    /// - width: 当前真实 Tab 宽度。
    /// 返回：同一来源内替换暂未排版窗口，迟到、取消或超量时保留原文和选择。
    private func prepareWideLine(snapshot: DocumentSnapshot, key: EditorWideTabLayout.Key, width: Int) {
        wideTabLayout.task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                if let columns = try ASCIITabColumns(
                    text: snapshot.text,
                    range: key.range,
                    tabWidth: width,
                    deadline: deadline
                ) {
                    return EditorWideTabLayout.Entry(columns: columns, han: nil, status: nil)
                }
                let han = try PlainHanLine(text: snapshot.text, range: key.range, deadline: deadline)
                return EditorWideTabLayout.Entry(columns: nil, han: han, status: nil)
            }
            let entry: EditorWideTabLayout.Entry?
            do {
                let measured = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                try Task.checkCancellation()
                entry = measured
            }
            catch is CancellationError {
                entry = nil
            }
            catch {
                entry = EditorWideTabLayout.Entry(columns: nil, han: nil, status: error.localizedDescription)
            }
            guard let self else {
                return
            }
            self.wideTabLayout.task = nil
            // 等待中的其它长行也要取得下一次测量机会，已经排好的短行和长行继续复用。
            self.layouts = self.layouts.filter { $0.value.unavailableReason == nil }
            self.needsDisplay = true
            guard let entry, self.wideTabKey(key.range) == key,
                !self.wrapLines, !self.rtl, self.composition == nil
            else {
                return
            }
            self.wideTabLayout.entries[key] = entry
            guard let request = self.wideTabLayout.pendingReveal, request.key == key else {
                return
            }
            self.wideTabLayout.pendingReveal = nil
            // 后台完成只恢复原本等待的光标定位，用户后来滚动、换焦或修改选区都优先。
            if entry.columns != nil || entry.han != nil,
                self.selectionGeneration == request.selection, self.focusGeneration == request.focus,
                self.visibleRect.origin == request.viewport,
                self.layoutLine(snapshot.text.lineNumber(at: key.range.lower)).unavailableReason == nil
            {
                self.revealSelection()
            }
        }
    }
}
