import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：直接配对输入与语义宏沿同一完整事务提交，插入内部光标不制造第二次正文操作。
    /// 参数说明:
    /// - command: 已明确固定的配对定义、实际字符和闭合越过选项。
    /// 返回：完整提交时为真并通知独立宏事件；候选、权限、矩形或准备失败时全部原状态保持不变。
    @discardableResult
    public func submitPairInput(_ command: PairInputCommand) -> Bool {
        // 配对不能借输入辅助提前消费候选或取得只读文档的选择修改权。
        guard !confirmingComposition, composition == nil, !document.isReadOnly, !document.isEditingSuspended,
            synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许配对输入，原状态保持不变。")
            return false
        }
        do {
            let prepared = try preparePairInput(command, completeOpening: true)
            let changed = try document.commit(prepared.transaction)
            if let state = document.selectionState {
                adoptViewSelectionState(state)
            }
            refresh(reveal: true)
            onPairInput?(command)
            if changed {
                onChange?()
            }
            else {
                onSelection?()
            }
            onCommand?("typingAssistance")
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：自动配对关闭时仍允许结构对齐，实际字符与前导空白作为一个语义输入提交。
    /// 参数说明:
    /// - command: 明确保存受支持界定符的输入动作。
    /// 返回：全部目标一次成功提交时为真；候选、权限或准备失败保留原状态且不记录输入。
    func insertStructuralCharacter(_ command: EditorCommand) -> Bool {
        guard let value = command.structuralCharacter, composition == nil,
            !document.isReadOnly, !document.isEditingSuspended, synchronizeDocumentSelectionState()
        else {
            onStatus?("当前候选或编辑权限不允许结构字符输入。")
            return false
        }
        do {
            let pair: AutomaticPair
            switch value {
            case "{", "}": pair = try AutomaticPair(opening: "{", closing: "}")
            case "[", "]": pair = try AutomaticPair(opening: "[", closing: "]")
            case ")": pair = try AutomaticPair(opening: "(", closing: ")")
            default: throw NateError.invalidRange
            }
            let input = try PairInputCommand(
                pair: pair,
                input: value,
                skipExisting: false
            )
            let prepared = try preparePairInput(input, completeOpening: false)
            try commitPreparedEditorInput(prepared.transaction)
            return true
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：配对及独立字符共享同一快照和截止，结构判断不能生成第二次缩进事务。
    /// 参数说明:
    /// - command: 固定两端定义、实际输入和越过策略。
    /// - completeOpening: 是否为开端生成完整一对。
    /// 返回：全部目标及其前缀已经验证的唯一输入事务，任一准备失败则抛错。
    private func preparePairInput(_ command: PairInputCommand, completeOpening: Bool) throws
        -> PreparedPairInsertion
    {
        let snapshot = document.snapshot
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let permit: @Sendable () -> Bool = {
            ContinuousClock.now < deadline
        }
        let structure: StructuralCharacterIndentationPlan?
        if indentationSettings.automatic == .language,
            ["{", "}", "[", "]"].contains(command.input) || command.input == ")" && language?.id == "rust"
        {
            structure = try StructuralCharacterIndentationPlan(
                snapshot: snapshot,
                input: command.input,
                language: language,
                udl: userLanguage,
                settings: tabSettings,
                deadline: deadline,
                permit: permit
            )
        }
        else {
            structure = nil
        }
        let resolver: (@Sendable (SelectionEntry) throws -> String?)?
        if let structure {
            resolver = {
                try structure.prefix(for: $0, snapshot: snapshot)
            }
        }
        else {
            resolver = nil
        }
        return try PreparedPairInsertion(
            snapshot: snapshot,
            command: command,
            completeOpening: completeOpening,
            tabSettings: tabSettings,
            indentation: resolver,
            permit: permit
        )
    }
}
