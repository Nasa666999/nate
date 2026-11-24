import Foundation

public struct PreparedTabInsertion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：普通光标执行配置的单点输入，跨行普通选择以原物理行增加一级，整批形成一个撤销单元。
    /// 参数说明:
    /// - snapshot: 带完整选择身份的固定正文。
    /// - settings: 当前语言的明确 Tab 宽度与输入方式。
    /// - overwrite: 空光标是否覆盖同一行内一个完整字素，行结束符不参与覆盖。
    /// - preparedColumns: 给当前普通目标复用的同源、有界长行制表列证据。
    /// - preparedHan: 视图已确认的独立汉字长行证据，复用实际逻辑列和端点。
    /// - permit: 目标、列计算和事务构建共享的继续资格。
    /// 返回：保留身份、主项及原撤销来源的完整事务；任一列不合法时不提交部分光标。
    public init(
        snapshot: DocumentSnapshot,
        settings: TabSettings,
        overwrite: Bool = false,
        preparedColumns: [ASCIITabColumns] = [],
        preparedHan: [HanLogicalColumns] = [],
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        if let selection = snapshot.selectionState, case .stream = selection.shape,
            selection.entries.contains(where: {
                let range = $0.selection.range
                return !range.isEmpty
                    && snapshot.text.lineNumber(at: range.lower) != snapshot.text.lineNumber(at: range.upper)
            })
        {
            transaction = try PreparedMultilineTab.transaction(
                snapshot: snapshot,
                selection: selection,
                settings: settings,
                overwrite: overwrite,
                preparedColumns: preparedColumns,
                preparedHan: preparedHan,
                permit: permit
            )
            return
        }
        if !settings.useSpaces {
            transaction = try PreparedTextInsertion(
                snapshot: snapshot,
                value: "\t",
                overwrite: overwrite,
                name: "输入 Tab",
                permit: permit
            ).transaction
            return
        }
        guard let original = snapshot.selectionState, case .stream = original.shape else {
            throw NateError.message("普通 Tab 输入需要完整流式选择；矩形边缘须由实际视图另行证明。")
        }
        let normalized = try original.normalized(in: snapshot.text, permit: permit)
        var columns = try LogicalColumnReader(
            text: snapshot.text,
            tabWidth: settings.width,
            deadline: .now.advanced(by: .seconds(5)),
            preparedColumns: preparedColumns,
            preparedHan: preparedHan,
            permit: permit
        )
        var navigation = try GraphemeNavigation(text: snapshot.text)
        var targets: [SelectionInsertionTarget] = []
        for entry in normalized.entries {
            let selection = entry.selection
            let column = try columns.column(at: selection.range.lower, virtualColumn: selection.virtualColumn)
            var range = selection.range
            if overwrite, range.isEmpty, selection.virtualColumn == 0,
                range.lower
                    < snapshot.text.lineRange(snapshot.text.lineNumber(at: range.lower), includeEnding: false)
                    .upper
            {
                range = try navigation.range(at: range.lower, forward: true)
            }
            targets.append(
                SelectionInsertionTarget(
                    id: entry.id,
                    range: range,
                    text: String(repeating: " ", count: settings.width - column % settings.width),
                    leadingSpaces: selection.virtualColumn
                )
            )
        }
        transaction = try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: targets,
            primaryID: normalized.primaryID,
            name: "输入空格 Tab",
            permit: permit
        ).transaction
    }
}
