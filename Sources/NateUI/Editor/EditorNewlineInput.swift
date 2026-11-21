import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：真实 Return 按键按每项原选择及明确自动缩进规则准备换行。
    /// 参数说明: 无。
    /// 返回：全部目标完整提交时为真；候选、权限、原生矩形或缩进预算失败时原状态保持不变。
    @discardableResult
    func insertConfiguredNewline() -> Bool {
        guard composition == nil, !document.isReadOnly, !document.isEditingSuspended,
            synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许换行，正文与选择保持原状。")
            return false
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let permit: @Sendable () -> Bool = {
                ContinuousClock.now < deadline
            }
            try requireCurrentRectangleLayout()
            let targets: [NewlineInsertionTarget]?
            if let state = viewSelectionState, case .rectangle = state.shape {
                targets = try rectangularInsertionTargets(newline).map {
                    NewlineInsertionTarget(
                        id: $0.id,
                        range: $0.range,
                        leadingSpaces: $0.leadingSpaces,
                        trailingSpaces: $0.trailingSpaces
                    )
                }
            }
            else {
                targets = nil
            }
            let snapshot = document.snapshot
            let structure: StructuralIndentationPlan?
            if indentationSettings.automatic == .language {
                let ranges =
                    try targets?.map(\.range)
                    ?? snapshot.selectionState?.normalized(in: snapshot.text, permit: permit).entries.map(
                        \.selection.range
                    )
                    ?? []
                structure = try StructuralIndentationPlan(
                    snapshot: snapshot,
                    language: language,
                    udl: userLanguage,
                    ranges: ranges,
                    deadline: deadline,
                    permit: permit
                )
            }
            else {
                structure = nil
            }
            let resolver: (@Sendable (NewlineInsertionTarget) throws -> NewlineIndentationAction)?
            if let context = structure {
                resolver = {
                    target in
                    try context.action(for: target, snapshot: snapshot)
                }
            }
            else {
                resolver = nil
            }
            let plan = try PreparedNewlineInsertion(
                snapshot: snapshot,
                targets: targets,
                inheritIndentation: indentationSettings.automatic != .disabled,
                tabSettings: tabSettings,
                structuralIndentation: resolver,
                permit: permit
            )
            try commitPreparedEditorInput(plan.transaction)
            if structure?.usesLanguageRules == false {
                onStatus?("当前语言没有适用的块缩进规则，本次完整继承原行缩进。")
            }
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：已完整准备的结构化输入只发布一次，正文、完整结果选择和后续界面通知保持顺序。
    /// 参数说明:
    /// - transaction: 与当前正文和选择身份绑定的完整输入计划。
    /// 返回：真实提交后刷新并通知；计划失效或权限不符时抛错，不发布部分结果或宏事件。
    func commitPreparedEditorInput(_ transaction: PreparedTransaction) throws {
        let changed = try document.commit(transaction)
        refresh(reveal: true)
        if changed {
            onChange?()
        }
        else {
            onSelection?()
        }
        onCommand?("typingAssistance")
    }
}
