import AppKit
import NateCore

extension EditorView {
    public var delimiterSelectionSettings: DelimiterSelectionSettings {
        boundaries.delimiters
    }

    /// 业务作用：分隔符规则应用到后续选择，等待旧字符或范围的结果立即失权。
    /// 参数说明:
    /// - settings: 已完整验证的两个标量及扫描范围。
    /// 返回：只发布规则，不重新解释现有选区，也不修改正文历史。
    public func setDelimiterSelectionSettings(_ settings: DelimiterSelectionSettings) {
        guard boundaries.delimiters != settings else {
            return
        }
        boundaries.cancelDelimiterSelection()
        boundaries.delimiterGeneration = UUID()
        boundaries.delimiters = settings
    }

    /// 业务作用：在后台准备分隔符内部选择，只有原视图、正文、焦点、选区和规则仍有效时发布。
    /// 参数说明:
    /// - position: 点击或主光标的完整原文字节位置。
    /// 返回：成对时一次替换本视图选择；未成对、过期、取消或超限均保留原选择。
    public func selectInsideConfiguredDelimiters(at position: Int) {
        guard composition == nil, !document.isEditingSuspended,
            window?.firstResponder === self, document.text.isBoundary(position)
        else {
            onStatus?("请先结束候选或编辑保护，并将焦点放在正文。")
            return
        }
        boundaries.cancelDelimiterSelection()
        let request = boundaries.request
        let rules = boundaries.delimiters
        let generation = boundaries.delimiterGeneration
        let source = document
        let snapshot = source.snapshot
        let editing = source.editingAuthorityGeneration
        let selection = selectionGeneration
        let focus = focusGeneration
        dragAnchor = nil
        dragColumn = nil
        dragRevision = nil
        dragSelectionID = nil
        dragAppending = false
        onStatus?("正在查找配置的分隔符对…")
        boundaries.task = Task {
            [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try PreparedDelimiterSelection(text: snapshot.text, position: position, settings: rules)
            }
            let result: Result<PreparedDelimiterSelection, Error> = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            defer {
                if let self, boundaries.request == request {
                    boundaries.task = nil
                }
            }
            // 值相同的规则往返也不能恢复来源；新候选、保护、焦点或选择变化必须保留当前状态。
            guard let self, !Task.isCancelled, boundaries.request == request,
                boundaries.delimiterGeneration == generation, document === source,
                document.revision == snapshot.revision, selectionGeneration == selection,
                document.editingAuthorityGeneration == editing,
                focusGeneration == focus, composition == nil, !document.isEditingSuspended,
                window?.firstResponder === self
            else {
                return
            }
            switch result {
            case .success(let plan):
                guard let selected = plan.selection else {
                    onStatus?("当前位置没有完整的配置分隔符对，原选区保留。")
                    return
                }
                do {
                    try setSelectionState(SelectionState(selections: [selected]))
                    onSelection?()
                    revealSelection(selected)
                    onStatus?("已按配置选择分隔符之间的正文。")
                }
                catch {
                    onStatus?(error.localizedDescription)
                }
            case .failure(let error):
                onStatus?(error.localizedDescription)
            }
        }
    }
}
