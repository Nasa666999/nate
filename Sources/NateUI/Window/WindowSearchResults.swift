import AppKit

extension EditorWindow {
    /// 业务作用：完整搜索历史进入独立树形结果，用户正在选择工具输出时不强制更换其当前视图。
    /// 参数说明:
    /// - batches: 当前保留的完整查询批次。
    /// 返回：合法结果进入面板并按当前已确认筛选呈现，正文焦点与源选区保持原状。
    public func presentSearchResults(_ batches: [SearchResultBatchPresentation]) throws {
        try searchResults.present(batches)
        resultGeneration = UUID()
        if resultsScroll.isHidden || !resultContainsResponder(resultsScroll) {
            resultsScroll.isHidden = true
            searchResults.isHidden = false
        }
        revealResultArea()
    }

    /// 业务作用：显式重新显示已有搜索批次，隐藏结果不清除查询、文档或结果历史。
    /// 参数说明: 无。
    /// 返回：搜索树显示；仅原焦点属于被隐藏工具输出时才转交到结果树。
    public func showSearchResultHistory() {
        let transfer = resultContainsResponder(resultsScroll)
        resultsScroll.isHidden = true
        searchResults.isHidden = false
        resultGeneration = UUID()
        revealResultArea()
        if transfer {
            window?.makeFirstResponder(searchResults.outline)
        }
    }

    /// 业务作用：用户明确请求时切换到完整工具输出，不通过隐藏结果树提交未确认的筛选。
    /// 参数说明: 无。
    /// 返回：没有筛选候选或草稿时显示工具输出，否则保留原输入并明确反馈。
    public func showToolOutput() {
        // 未确认筛选仍持有原生输入上下文，切换视图不能暗中替用户确认或丢弃草稿。
        guard !searchResults.isEditingInput else {
            status.stringValue = "请先确认或取消结果筛选输入，再切换工具输出。"
            return
        }
        let transfer = resultContainsResponder(searchResults)
        searchResults.isHidden = true
        resultsScroll.isHidden = false
        resultGeneration = UUID()
        revealResultArea()
        if transfer {
            window?.makeFirstResponder(results)
        }
    }

    /// 业务作用：关闭底部结果只改变显示，输入草稿未确认时保留其上下文，文档和批次始终独立存在。
    /// 参数说明:
    /// - visible: 是否恢复当前结果视图。
    /// 返回：合法显示变更完成，关闭时撤销旧定位资格并在需要时交还正文焦点。
    public func setResultsVisible(_ visible: Bool) {
        guard visible || searchResults.isHidden || !searchResults.isEditingInput else {
            status.stringValue = "请先确认或取消结果筛选输入，再隐藏结果。"
            return
        }
        let transfer = !visible && resultContainsResponder(resultHost)
        resultGeneration = UUID()
        resultHost.isHidden = !visible
        if visible {
            revealResultArea()
        }
        else {
            window?.contentView?.layoutSubtreeIfNeeded()
            split.adjustSubviews()
        }
        if transfer {
            window?.makeFirstResponder(editor)
        }
    }

    /// 业务作用：结果区域按实际窗口尺寸分配底部空间，小窗口保留正文并让工具和结果保持可操作。
    /// 参数说明: 无。
    /// 返回：底部区域可见且布局完成，不调用输入确认或修改正文选择。
    func revealResultArea() {
        resultHost.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        let bottom = min(240, max(140, split.bounds.height * 0.45))
        split.setPosition(max(100, split.bounds.height - bottom), ofDividerAt: 0)
        window?.contentView?.layoutSubtreeIfNeeded()
        refreshEditors()
    }

    /// 业务作用：后台输出识别用户是否正在结果内交互，不能通过换面板改变其输入和复制目标。
    /// 参数说明:
    /// - view: 需要保护的当前结果区域。
    /// 返回：实际原生首响应者属于该区域时为真，不获取或改变焦点。
    func resultContainsResponder(_ view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else {
            return false
        }
        return responder === view || responder.isDescendant(of: view)
    }
}
