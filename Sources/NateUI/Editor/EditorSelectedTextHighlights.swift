import AppKit
import NateCore
import NateSearch

extension EditorView {
    /// 业务作用：状态栏可观察智能高亮的容量与计算边界，不把失败误报成完整无匹配。
    /// 参数说明: 无。
    /// 返回：当前视口的实际失败或不可定位提示，正常及未启用时为空。
    public var selectedTextHighlightStatus: String? {
        selectedTextHighlights.failure
    }

    /// 业务作用：结束当前视图的智能匹配，旧结果不能在来源、选区或设置往返后重新出现。
    /// 参数说明: 无。
    /// 返回：先撤销身份再取消后台计算，清除该临时图层；其它图层与文档颜色保持原样。
    func cancelSelectedTextHighlights() {
        if selectedTextHighlights.key != nil || selectedTextHighlights.task != nil {
            selectedTextHighlights.generation = UUID()
            selectedTextHighlights.task?.cancel()
            selectedTextHighlights.task = nil
            selectedTextHighlights.key = nil
        }
        if textHighlights[.selectedText] != nil {
            setTextHighlights(nil, for: .selectedText)
        }
        selectedTextHighlights.failure = nil
    }

    /// 业务作用：只枚举当前视口的可见逻辑行，折叠区域不被当作连续全文搜索范围。
    /// 参数说明: 无。
    /// 返回：至多 400 个行区间；没有实际视口时为空，普通相邻行共享一个搜索区间。
    func selectedTextHighlightScopes() -> [ByteRange] {
        guard window != nil, !visibleRect.isEmpty else {
            return []
        }
        let first = projection.line(at: max(0, visibleRect.minY - 8))
        let last = min(document.text.lineCount - 1, projection.line(at: visibleRect.maxY) + 1)
        guard first <= last else {
            return []
        }
        var scopes: [ByteRange] = []
        for line in projection.visibleLines(in: first...last).prefix(400) {
            let range = document.text.lineRange(line)
            if let previous = scopes.last, previous.upper == range.lower {
                scopes[scopes.count - 1] = ByteRange(previous.lower, range.upper)
            }
            else {
                scopes.append(range)
            }
        }
        return scopes
    }

    /// 业务作用：绘制与状态刷新只调度当前选区的有界后台匹配，缓存相同来源和视口，不在主线程扫描正文。
    /// 参数说明: 无。
    /// 返回：新条件取消旧任务后生成独立绿色图层；候选、保护或来源失效时清除旧坐标，不改变正文与选区。
    public func prepareSelectedTextHighlights() {
        guard let provider = selectedTextHighlightContext else {
            return
        }
        guard let context = provider(), context.settings.options.enabled,
            !hasComposition, !context.source.hasComposition,
            !document.isEditingSuspended, !context.source.document.isEditingSuspended,
            context.source.viewSelections.count == 1,
            let selection = context.source.primarySelection,
            !selection.range.isEmpty, selection.virtualColumn == 0
        else {
            cancelSelectedTextHighlights()
            return
        }
        let scopes = selectedTextHighlightScopes()
        guard !scopes.isEmpty else {
            cancelSelectedTextHighlights()
            return
        }
        let source = context.source
        let key = SelectedTextHighlightKey(
            target: ObjectIdentifier(document),
            targetRevision: document.revision,
            source: ObjectIdentifier(source.document),
            sourceView: ObjectIdentifier(source),
            sourceRevision: source.document.revision,
            selectionGeneration: source.selectionGeneration,
            selections: source.viewSelections,
            scopes: scopes,
            settings: context.settings
        )
        if selectedTextHighlights.key == key {
            return
        }
        cancelSelectedTextHighlights()
        selectedTextHighlights.key = key
        let generation = selectedTextHighlights.generation
        let sourceSnapshot = source.document.snapshot
        let targetSnapshot = document.snapshot
        let current: @MainActor () -> Bool = {
            [weak self, weak source] in
            // 来源选择和目标视口分别绑定真实实例与修订；任一候选、保护或身份变化都撤销旧范围。
            guard let self, let source, !Task.isCancelled,
                self.selectedTextHighlights.generation == generation,
                let latest = self.selectedTextHighlightContext?(), latest.source === source,
                latest.settings == key.settings, ObjectIdentifier(self.document) == key.target,
                self.document.revision == key.targetRevision,
                ObjectIdentifier(source.document) == key.source,
                source.document.revision == key.sourceRevision,
                source.selectionGeneration == key.selectionGeneration,
                source.viewSelections == key.selections,
                !self.hasComposition, !source.hasComposition,
                !self.document.isEditingSuspended, !source.document.isEditingSuspended,
                self.selectedTextHighlightScopes() == key.scopes
            else {
                return false
            }
            return true
        }
        selectedTextHighlights.task = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.selectedTextHighlights.generation == generation {
                    self.selectedTextHighlights.task = nil
                }
            }
            do {
                // 拖选与连续键盘扩展只计算最后一份完整选择，等待可取消且不占用正文执行域。
                try await Task.sleep(for: .milliseconds(120))
                guard current() else {
                    if self.selectedTextHighlights.generation == generation {
                        self.selectedTextHighlights.key = nil
                    }
                    return
                }
                let settings = key.settings
                let sensitive =
                    settings.options.useFindOptions
                    ? settings.findCaseSensitive : settings.options.caseSensitive
                let whole =
                    settings.options.useFindOptions ? settings.findWholeWord : settings.options.wholeWord
                let worker = Task.detached(priority: .utility) {
                    try SelectedTextHighlighting.prepare(
                        source: sourceSnapshot,
                        selections: key.selections,
                        target: targetSnapshot,
                        scopes: key.scopes,
                        caseSensitive: sensitive,
                        wholeWord: whole,
                        wordBoundaries: settings.wordBoundaries,
                        permit: {
                            !Task.isCancelled
                        }
                    )
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                guard current() else {
                    if self.selectedTextHighlights.generation == generation {
                        self.selectedTextHighlights.key = nil
                    }
                    return
                }
                self.setTextHighlights(result.highlights, for: .selectedText)
                self.selectedTextHighlights.failure =
                    result.unmapped > 0 ? "智能高亮有 \(result.unmapped) 处无法无损定位。" : nil
            }
            catch {
                if current(), !(error is CancellationError) {
                    self.selectedTextHighlights.failure = error.localizedDescription
                    self.onStatus?(error.localizedDescription)
                }
                else if self.selectedTextHighlights.generation == generation {
                    self.selectedTextHighlights.key = nil
                }
            }
        }
    }
}
