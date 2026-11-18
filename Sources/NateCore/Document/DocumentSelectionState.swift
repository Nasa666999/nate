import Foundation

extension DocumentBuffer {
    /// 业务作用：文档命令、状态栏与运行变量读取明确主项，不把选择数组顺序当作控制角色。
    /// 参数说明: 无。
    /// 返回：当前完整状态中的主选区；几何无法完整表示时为空。
    public var primarySelection: TextSelection? {
        selectionState?.primary.selection
    }

    /// 业务作用：兼容原几何入口时同步稳定身份，非法集合不能继续作为后来正文事务的选择来源。
    /// 参数说明: 无。
    /// 返回：合法几何匹配原身份并推进选择代次；无法完整表示时保留原几何并关闭稳定状态发布资格。
    func synchronizeLegacySelectionState() {
        selectionGeneration = UUID()
        do {
            if let selectionState {
                self.selectionState = try selectionState.acceptingGeometries(selections)
            }
            else {
                selectionState = try SelectionState(selections: selections)
            }
        }
        catch {
            // 原赋值已发生，不能悄悄用先前合法光标继续编辑；完整状态缺失使后续事务明确拒绝。
            selectionState = nil
        }
    }

    /// 业务作用：明确发布当前正文上的完整选择、主项与形态，不把它登记为正文编辑或撤销项。
    /// 参数说明:
    /// - state: 与当前正文完整匹配的稳定选择集合。
    /// 返回：完整更新选择并收回旧计划资格；保护、非法边界或取消时保留原选择。
    public func setSelectionState(_ state: SelectionState) throws {
        // 关闭保护已固定视图元数据，完整形态入口也不能在保护期间改写选择。
        guard !isEditingSuspended else {
            throw NateError.message("文档处于编辑保护，选择保持原状。")
        }
        _ = try state.validated(in: text)
        publishSelectionState(state)
    }

    /// 业务作用：所有可失败选择准备结束后一次发布几何和身份，避免兼容 setter 再次分配或清除形态。
    /// 参数说明:
    /// - state: 已通过当前正文边界与形态校验的完整状态。
    /// 返回：完整状态变化时推进独立控制身份；正文、保存和历史保持不变。
    func publishSelectionState(_ state: SelectionState) {
        let changed = selectionState != state
        publishingSelectionState = true
        selections = state.selections
        publishingSelectionState = false
        selectionState = state
        if changed {
            selectionGeneration = UUID()
        }
    }
}
