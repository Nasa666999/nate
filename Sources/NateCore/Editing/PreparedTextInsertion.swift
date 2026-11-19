import Foundation

public struct PreparedTextInsertion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：在原选择不变的快照上准备整次输入，系统替换范围与覆盖目标不会提前改写撤销来源。
    /// 参数说明:
    /// - snapshot: 包含完整选择身份与控制代次的原正文。
    /// - value: 用户确认的完整文字，不包含为虚拟列生成的空白。
    /// - replacementRange: 仅替代主选区的系统范围，其余明确目标继续参与。
    /// - overwrite: 无系统替换范围时，单行输入覆盖空光标所在行内的一个完整字形簇。
    /// - name: 本次输入的撤销名称。
    /// - permit: 全部目标、空白与正文准备共用的执行资格。
    /// 返回：含完整结果选择的事务；超量、非法目标或取消时不发布中间选择与部分正文。
    public init(
        snapshot: DocumentSnapshot,
        value: String,
        replacementRange: ByteRange? = nil,
        overwrite: Bool = false,
        name: String = "输入",
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil else {
            throw NateError.message("输入需要原文档的完整选择身份。")
        }
        _ = try original.validated(in: snapshot.text, permit: permit)
        // 旧矩形必须先重新定义列边缘，不能经普通输入入口绕过半个 Tab 的保护。
        if case .rectangle(let rectangle) = original.shape, rectangle.needsRevalidation {
            throw NateError.message("矩形正文已经改变，请重新选择边缘后再输入。")
        }
        let size = value.utf8.count
        guard size <= 64 * 1024 * 1024 else {
            throw NateError.message("单次输入超过 64 MiB，正文保持原状。")
        }
        if let replacementRange {
            guard replacementRange.lower >= 0, replacementRange.upper >= replacementRange.lower,
                snapshot.text.isBoundary(replacementRange.lower),
                snapshot.text.isBoundary(replacementRange.upper)
            else {
                throw NateError.invalidRange
            }
        }
        let canOverwrite =
            replacementRange == nil && overwrite && size > 0
            && !value.utf8.contains(10) && !value.utf8.contains(13)
        var navigation = try GraphemeNavigation(text: snapshot.text)
        var entries: [SelectionEntry] = []
        for (index, entry) in original.entries.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            var selection = entry.selection
            if entry.id == original.primaryID, let replacementRange {
                selection = TextSelection(anchor: replacementRange.lower, head: replacementRange.upper)
            }
            else if canOverwrite, selection.range.isEmpty, selection.virtualColumn == 0 {
                let row = snapshot.text.lineNumber(at: selection.head)
                let body = snapshot.text.lineRange(row, includeEnding: false)
                // 行尾没有可覆盖的正文；覆盖不能吞掉 CRLF，也不能把下一行并入当前行。
                if selection.head < body.upper {
                    let range = try navigation.range(at: selection.head, forward: true)
                    guard range.lower >= body.lower, range.upper <= body.upper else {
                        throw NateError.invalidRange
                    }
                    selection = TextSelection(anchor: range.lower, head: range.upper)
                }
            }
            // 系统范围可以跨行，但不能在 CR 与 LF 之间开始或结束一次普通输入。
            for point in [selection.range.lower, selection.range.upper] {
                guard !(snapshot.text.byte(at: point - 1) == 13 && snapshot.text.byte(at: point) == 10) else {
                    throw NateError.message("输入范围不能切开 CRLF，正文与选择保持原状。")
                }
            }
            entries.append(SelectionEntry(id: entry.id, selection: selection))
        }
        let targets = try SelectionState(entries: entries, primaryID: original.primaryID)
            .normalized(in: snapshot.text, permit: permit)
        var delta = 0
        var output = 0
        for (index, entry) in targets.entries.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            let selection = entry.selection
            let padding = size == 0 ? 0 : selection.virtualColumn
            let inserted = size + padding
            guard inserted <= 256 * 1024 * 1024 - output else {
                throw NateError.message("全部输入目标超过 256 MiB，未提交部分内容。")
            }
            output += inserted
            delta += inserted - selection.range.count
        }
        let finalSize = snapshot.text.byteCount.addingReportingOverflow(delta)
        guard !finalSize.overflow, finalSize.partialValue <= 1024 * 1024 * 1024 else {
            throw NateError.message("输入后正文超过 1 GiB，正文与选择保持原状。")
        }
        // 所有容量门禁先于填充字符串分配，后面的目标超限时不会先创建大量无用空白。
        var edits: [TextEdit] = []
        var collapsed: [UUID: SelectionEntry] = [:]
        delta = 0
        for (index, entry) in targets.entries.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            let selection = entry.selection
            let padding = size == 0 ? 0 : selection.virtualColumn
            let inserted = size + padding
            let position = selection.range.lower + delta + inserted
            delta += inserted - selection.range.count
            collapsed[entry.id] = SelectionEntry(
                id: entry.id,
                selection: TextSelection(
                    anchor: position,
                    head: position,
                    virtualColumn: size == 0 && selection.range.isEmpty ? selection.virtualColumn : 0
                )
            )
            edits.append(TextEdit(selection.range, String(repeating: " ", count: padding) + value))
        }
        // 按原建立顺序发布仍存活的身份，文档顺序只用于计算编辑位置，不能改变主项或追加顺序。
        let result: SelectionState
        if size == 0, replacementRange == nil,
            original.entries.allSatisfy({
                $0.selection.range.isEmpty
            })
        {
            result = original
        }
        else {
            result = try SelectionState(
                entries: original.entries.compactMap {
                    collapsed[$0.id]
                },
                primaryID: targets.primaryID
            )
        }
        try budget.check()
        transaction = try PreparedTransaction(
            snapshot: snapshot,
            edits: edits,
            selectionStateAfter: result,
            name: name,
            permit: permit
        )
        try budget.check()
    }
}
