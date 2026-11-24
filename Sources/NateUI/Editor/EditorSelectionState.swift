import AppKit
import NateCore

extension EditorView {
    /// 业务作用：输入法、导航和呈现使用明确主项，不把数组顺序当作主选区身份。
    /// 参数说明: 无。
    /// 返回：当前完整状态的真实主选区；无合法身份集合时为空。
    public var primarySelection: TextSelection? {
        viewSelectionState?.primary.selection
    }

    /// 业务作用：显式设置当前视图的稳定选择和完整形态，活动视图同时交给唯一文档历史入口。
    /// 参数说明:
    /// - state: 属于当前正文的完整选择、主项与形态。
    /// 返回：全部校验成功后发布；候选、保护、非法范围或取消时保留原视图状态。
    public func setSelectionState(_ state: SelectionState) throws {
        // 候选与关闭保护持有当前元数据，外部完整选择不能在其间改变组合目标或恢复记录。
        guard composition == nil, !document.isEditingSuspended else {
            throw NateError.message("请先结束候选或编辑保护，再改变完整选择。")
        }
        let state = try bindingRectangleLayout(state)
        if window?.isKeyWindow == true, window?.firstResponder === self {
            try document.setSelectionState(state)
        }
        else {
            _ = try state.validated(in: document.text)
        }
        adoptViewSelectionState(state)
    }

    /// 业务作用：用户明确切换主项时保留其余选择顺序与方向，并撤销等待原主项的后台导航。
    /// 参数说明:
    /// - id: 本视图仍存在的稳定选择身份。
    /// 返回：完整切换主项并通知工作区；陌生身份或保护期间失败且不改变正文。
    public func selectPrimarySelection(_ id: UUID) throws {
        guard let viewSelectionState else {
            throw NateError.message("当前选择缺少完整身份。")
        }
        try setSelectionState(viewSelectionState.selectingPrimary(id))
        onSelection?()
    }

    /// 业务作用：兼容几何赋值同步保留身份，实际已发生的视图变化不受旧后台任务取消状态影响。
    /// 参数说明: 无。
    /// 返回：完整记录新几何；无效集合撤销稳定状态并提示原因，后续输入不使用旧文档选择。
    func synchronizeLegacyViewSelectionState() {
        clipboard.cancel()
        rectangleProjectionGeneration = nil
        rectangleProjectionCache = [:]
        selectionGeneration = UUID()
        do {
            if let viewSelectionState {
                self.viewSelectionState = try viewSelectionState.acceptingGeometries(viewSelections)
            }
            else {
                viewSelectionState = try SelectionState(selections: viewSelections)
            }
            selectionStateRevision = document.revision
        }
        catch {
            viewSelectionState = nil
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：只有本视图的当前完整状态才能成为实际输入来源，不能沿先前文档光标继续编辑。
    /// 参数说明: 无。
    /// 返回：状态与修订有效且文档接纳时为真；失败保留文档并反馈具体原因。
    @discardableResult
    func synchronizeDocumentSelectionState() -> Bool {
        guard selectionStateRevision == document.revision, let viewSelectionState else {
            onStatus?("当前视图选择缺少完整修订证据，请重新选择正文。")
            return false
        }
        if document.selectionState == viewSelectionState {
            return true
        }
        do {
            try document.setSelectionState(viewSelectionState)
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：已完整准备的文档或克隆状态直接接管，不经过几何兼容入口重新分配身份或清除矩形。
    /// 参数说明:
    /// - state: 已验证属于当前正文的完整不可变状态。
    /// 返回：几何、身份和形态同时呈现，完整状态变化时推进本视图选择代次，不修改文档。
    func adoptViewSelectionState(_ state: SelectionState) {
        let changed = viewSelectionState != state
        publishingViewSelectionState = true
        viewSelections = state.selections
        publishingViewSelectionState = false
        viewSelectionState = state
        selectionStateRevision = document.revision
        if changed {
            clipboard.cancel()
            rectangleProjectionGeneration = nil
            rectangleProjectionCache = [:]
            selectionGeneration = UUID()
        }
        needsDisplay = true
    }

    /// 业务作用：克隆重新取得焦点前先跨过完整位置链，旧修订光标不能直接写入最新正文。
    /// 参数说明: 无。
    /// 返回：原身份可映射时保留独立选择；缺链时采用当前文档合法状态并说明原因，不抢其它视图焦点。
    func synchronizeViewSelectionRevision() {
        guard selectionStateRevision != document.revision else {
            return
        }
        if let viewSelectionState,
            let mapped = document.mapSelectionState(viewSelectionState, from: selectionStateRevision)
        {
            adoptViewSelectionState(mapped)
        }
        else if let state = document.selectionState {
            adoptViewSelectionState(state)
            onStatus?("原视图选择超出完整修订链，已同步当前文档的合法选择。")
        }
        else {
            viewSelections = document.selections
            onStatus?("当前文档选择无法完整恢复，请重新选择正文。")
        }
    }
}
