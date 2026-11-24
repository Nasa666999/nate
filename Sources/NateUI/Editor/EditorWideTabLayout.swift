import AppKit
import NateCore

@MainActor
final class EditorWideTabLayout {
    struct Key: Hashable, Sendable {
        let documentID: UUID
        let revision: UInt64
        let range: ByteRange
        let tabGeneration: UUID
        let geometryGeneration: UUID
    }

    struct Entry: Sendable {
        let columns: ASCIITabColumns?
        let han: PlainHanLine?
        var hanTabs: HanTabColumns? = nil
        let status: String?
        var wordWrap: ASCIIWordWrapIndex? = nil
        var narrow: PlainNarrowUnicodeLine? = nil

        /// 业务作用：编辑与当前实际显示共用已经确认的长行原始字节证据。
        /// 参数说明: 无。
        /// 返回：可安全处理真实 Tab、独立汉字或其它已证明字母的逻辑列来源。
        var logicalHan: HanLogicalColumns? {
            if let hanTabs {
                return .tabbed(hanTabs)
            }
            if let narrow {
                return .narrow(narrow)
            }
            return han.map(HanLogicalColumns.plain)
        }
    }

    struct Reveal {
        let key: Key
        let selection: UUID
        let focus: UUID
        let viewport: NSPoint
    }

    static let measuring = "正在测量超长逻辑行的可见范围。"
    var entries: [Key: Entry] = [:]
    var geometryGeneration = UUID()
    var task: Task<Void, Never>?
    var pendingReveal: Reveal?

    /// 业务作用：变化后的视图不能沿旧正文或旧列宽使用延迟测量，只在实际任务返回后释放唯一任务位。
    /// 参数说明: 无。
    /// 返回：旧缓存及导航意图失效，仍在运行的测量收到取消。
    func reset() {
        geometryGeneration = UUID()
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
        guard !rtl, composition == nil,
            range.count > EditorNativeLayoutPolicy.maximumParagraphBytes,
            snapshot.text.byteCount <= EditorNativeLayoutPolicy.maximumDocumentBytes
        else {
            return EditorWideTabLayout.Entry(columns: nil, han: nil, status: nil)
        }
        let printable = snapshot.text.isPrintableASCII(in: range)
        if wrapLines ? snapshot.text.isAlphanumericASCII(in: range) : printable {
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
            if wrapLines {
                let actual = EditorThemePresentation.baseFont(
                    font,
                    theme: editorTheme?.definition,
                    language: language?.id,
                    adjustment: fontZoomAdjustment
                )
                guard
                    let grid = WrappedASCIIWindow.referenceGeometry(
                        font: actual,
                        width: nativeBodyLayoutWidth,
                        appearance: effectiveAppearance
                    )
                else {
                    return EditorWideTabLayout.Entry(columns: nil, han: nil, status: nil)
                }
                let hanColumns = wideHanWrappingColumns(snapshot: snapshot, range: range, font: actual)
                prepareWideLine(
                    snapshot: snapshot,
                    key: key,
                    width: tabSettings.width,
                    wrappingColumns: (grid.columns, hanColumns)
                )
            }
            else {
                prepareWideLine(snapshot: snapshot, key: key, width: tabSettings.width)
            }
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
            tabGeneration: tabSettingsGeneration,
            geometryGeneration: wideTabLayout.geometryGeneration
        )
    }

    /// 业务作用：把超长行的原字节测量交给有限后台任务，发布前重新确认实际视图与行来源。
    /// 参数说明:
    /// - snapshot: 当前逻辑行所属的不可变正文。
    /// - key: 测量开始时固定的视图布局来源。
    /// - width: 当前真实 Tab 宽度。
    /// - wrappingColumns: 自动换行时实测的窄字形及可用的全角列数。
    /// 返回：同一来源内替换暂未排版窗口，迟到、取消或超量时保留原文和选择。
    private func prepareWideLine(
        snapshot: DocumentSnapshot,
        key: EditorWideTabLayout.Key,
        width: Int,
        wrappingColumns: (narrow: Int, fullWidth: Int?)? = nil
    ) {
        wideTabLayout.task = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let worker = Task.detached(priority: .userInitiated) {
                if let wrappingColumns {
                    let narrow = try PlainNarrowUnicodeLine(
                        text: snapshot.text,
                        range: key.range,
                        deadline: deadline
                    )
                    let index = try ASCIIWordWrapIndex(
                        text: snapshot.text,
                        range: key.range,
                        columns: wrappingColumns.narrow,
                        narrow: narrow,
                        deadline: deadline
                    )
                    if index == nil, let fullWidth = wrappingColumns.fullWidth,
                        let han = try PlainHanLine(text: snapshot.text, range: key.range, deadline: deadline),
                        han.characterCount * 3 == key.range.count
                    {
                        if han.containsOnlyUnifiedIdeographs {
                            return EditorWideTabLayout.Entry(columns: nil, han: han, status: nil)
                        }
                        let full = try ASCIIWordWrapIndex(
                            text: snapshot.text,
                            range: key.range,
                            columns: fullWidth,
                            fullWidth: han,
                            deadline: deadline
                        )
                        return EditorWideTabLayout.Entry(
                            columns: nil,
                            han: full == nil ? nil : han,
                            status: nil,
                            wordWrap: full
                        )
                    }
                    return EditorWideTabLayout.Entry(
                        columns: nil,
                        han: nil,
                        status: nil,
                        wordWrap: index,
                        narrow: index == nil ? nil : narrow
                    )
                }
                if let columns = try ASCIITabColumns(
                    text: snapshot.text,
                    range: key.range,
                    tabWidth: width,
                    deadline: deadline
                ) {
                    return EditorWideTabLayout.Entry(columns: columns, han: nil, status: nil)
                }
                if let narrow = try PlainNarrowUnicodeLine(
                    text: snapshot.text,
                    range: key.range,
                    deadline: deadline
                ) {
                    return EditorWideTabLayout.Entry(columns: nil, han: nil, status: nil, narrow: narrow)
                }
                let han = try PlainHanLine(text: snapshot.text, range: key.range, deadline: deadline)
                return EditorWideTabLayout.Entry(columns: nil, han: han, status: nil)
            }
            let entry: EditorWideTabLayout.Entry?
            do {
                var measured = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                try Task.checkCancellation()
                if wrappingColumns == nil, measured.columns == nil, measured.han == nil,
                    measured.narrow == nil,
                    let self, self.wideTabKey(key.range) == key,
                    let grid = self.wideHanTabMetrics(width: width)
                {
                    // 字体与语言设置已与测量身份绑定，后台只接收实际距离，视图更改后不会复用旧像素。
                    let mixed = Task.detached(priority: .userInitiated) {
                        try HanTabColumns(
                            text: snapshot.text,
                            range: key.range,
                            metrics: grid.metrics,
                            permitsFullWidthCharacters: grid.permitsFullWidth,
                            deadline: deadline
                        )
                    }
                    measured.hanTabs = try await withTaskCancellationHandler(
                        operation: { try await mixed.value },
                        onCancel: { mixed.cancel() }
                    )
                    try Task.checkCancellation()
                }
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
                self.wrapLines == (wrappingColumns != nil), !self.rtl, self.composition == nil
            else {
                return
            }
            self.wideTabLayout.entries[key] = entry
            guard let request = self.wideTabLayout.pendingReveal, request.key == key else {
                return
            }
            self.wideTabLayout.pendingReveal = nil
            // 后台完成只恢复原本等待的光标定位，用户后来滚动、换焦或修改选区都优先。
            if entry.columns != nil || entry.han != nil || entry.hanTabs != nil || entry.wordWrap != nil
                || entry.narrow != nil,
                self.selectionGeneration == request.selection, self.focusGeneration == request.focus,
                self.visibleRect.origin == request.viewport,
                self.layoutLine(snapshot.text.lineNumber(at: key.range.lower)).unavailableReason == nil
            {
                self.revealSelection()
            }
        }
    }

    /// 业务作用：源长度符合全角范围时测量级联字体的软换行容量，后台仍须确认每个原标量。
    /// 参数说明:
    /// - snapshot: 当前不可变的正文证据。
    /// - range: 当前完整逻辑行的原始范围。
    /// - font: 主题及缩放已经确定的基础字体。
    /// 返回：全角字体能在同一容器形成固定真实视觉列时提供列数。
    private func wideHanWrappingColumns(snapshot: DocumentSnapshot, range: ByteRange, font: NSFont) -> Int? {
        guard let start = snapshot.text.utf16Offset(byte: range.lower),
            let end = snapshot.text.utf16Offset(byte: range.upper),
            (end - start) * 3 == range.count,
            let han = NativeHanLineFont.resolve(from: font)
        else {
            return nil
        }
        return WrappedASCIIWindow.referenceGeometry(
            font: font,
            width: nativeBodyLayoutWidth,
            appearance: effectiveAppearance,
            hanFont: han
        )?.columns
    }

    /// 业务作用：长行制表只能沿所属真实视图的主题字体、字号与实际制表规则建立像素证据。
    /// 参数说明:
    /// - width: 当前语言已经确认的制表列数。
    /// 返回：具备实测步距与原生局部段落证明时提供度量，否则原段落保留明确暂停状态。
    private func wideHanTabMetrics(width: Int) -> (metrics: HanTabColumns.Metrics, permitsFullWidth: Bool)? {
        let actual = EditorThemePresentation.baseFont(
            font,
            theme: editorTheme?.definition,
            language: language?.id,
            adjustment: fontZoomAdjustment
        )
        guard let ascii = NativeMonospaceGeometry.uniformAdvance(actual, appearance: effectiveAppearance)
        else {
            return nil
        }
        if let full = NativeHanProjection.tabGrid(
            base: actual,
            ascii: ascii,
            width: width,
            appearance: effectiveAppearance
        ) {
            return (full, true)
        }
        guard
            NativeMonospaceGeometry.provesTabStops(
                actual,
                width: width,
                advance: ascii,
                appearance: effectiveAppearance
            ), let narrow = HanTabColumns.Metrics(asciiAdvance: ascii, hanAdvance: ascii, tabWidth: width)
        else {
            return nil
        }
        return (narrow, false)
    }

}
