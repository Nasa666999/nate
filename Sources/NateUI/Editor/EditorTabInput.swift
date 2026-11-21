import AppKit
import NateCore

extension EditorView {
    /// 业务作用：Tab 规则改变先撤销旧像素动作，再丢弃原生布局；正文与完整选择始终保留。
    /// 参数说明: 无。
    /// 返回：新规则立即影响后续布局和输入，旧后台任务不能因偏好往返重新取得资格。
    func tabSettingsDidChange() {
        // 列宽改变会令等待中的目标指向其它字节，先撤销控制身份，再建立新的显示证据。
        tabSettingsGeneration = UUID()
        clipboard.cancel()
        updateRectangleStyleIdentity()
        projection.measured.removeAll()
        refresh()
    }

    /// 业务作用：普通与矩形 Tab 输入均先准备全部真实目标，成功后才记录一次语义宏动作。
    /// 参数说明: 无。
    /// 返回：完整提交或合法选择收束时为真；只读、候选、布局与预算失败时不改变任何目标。
    @discardableResult
    func insertConfiguredTab() -> Bool {
        guard composition == nil, !document.isReadOnly, !document.isEditingSuspended,
            synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许 Tab 输入，正文与选择保持原状。")
            return false
        }
        do {
            try requireCurrentRectangleLayout()
            let transaction: PreparedTransaction
            if let state = viewSelectionState, case .rectangle = state.shape {
                transaction = try prepareRectangularTab()
            }
            else {
                transaction = try PreparedTabInsertion(
                    snapshot: document.snapshot,
                    settings: tabSettings,
                    overwrite: overwrite
                ).transaction
            }
            try commitPreparedEditorInput(transaction)
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：矩形 Tab 保留原生边缘涉及的两侧空白，每个目标按实际插入列决定空格数。
    /// 参数说明: 无。
    /// 返回：保留原形态作为撤销来源的完整事务；任何视觉边缘或逻辑列不能证明时整体拒绝。
    private func prepareRectangularTab() throws -> PreparedTransaction {
        let targets = try rectangularInsertionTargets("\t", overwrite: overwrite)
        if !tabSettings.useSpaces {
            return try PreparedSelectionInsertion(
                snapshot: document.snapshot,
                targets: targets,
                name: "输入 Tab"
            ).transaction
        }
        var reader = try LogicalColumnReader(
            text: document.text,
            tabWidth: tabSettings.width,
            deadline: .now.advanced(by: .seconds(2))
        )
        let converted = try targets.sorted {
            $0.range.lower < $1.range.lower
        }.map {
            target in
            let base = try reader.column(at: target.range.lower)
            // 实际前缀与保留空白共用列容量，不能让虚拟边缘绕过完整逻辑列上限。
            guard target.leadingSpaces <= 1_000_000 - base else {
                throw NateError.message("矩形 Tab 插入位置超过一百万逻辑列，全部目标保持原状。")
            }
            let column = base + target.leadingSpaces
            return SelectionInsertionTarget(
                id: target.id,
                range: target.range,
                text: String(repeating: " ", count: tabSettings.width - column % tabSettings.width),
                leadingSpaces: target.leadingSpaces,
                trailingSpaces: target.trailingSpaces
            )
        }
        return try PreparedSelectionInsertion(
            snapshot: document.snapshot,
            targets: converted,
            name: "输入空格 Tab"
        ).transaction
    }
}
