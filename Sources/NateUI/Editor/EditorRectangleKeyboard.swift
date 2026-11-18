import AppKit
import NateCore

extension EditorView {
    /// 业务作用：菜单按真实编辑视图的完整选择启用矩形扩展，只读仍可选择，候选和保护期间不改变目标。
    /// 参数说明: 无。
    /// 返回：当前单选择或明确矩形可扩展时为真，普通多选不猜测成矩形。
    public var canExtendRectangle: Bool {
        guard composition == nil, !document.isEditingSuspended,
            selectionStateRevision == document.revision, let viewSelectionState
        else {
            return false
        }
        if case .rectangle = viewSelectionState.shape {
            return true
        }
        return viewSelectionState.entries.count == 1
    }

    /// 业务作用：沿当前视图的空格像素宽度或相邻可见真实行延伸矩形，固定行与活动行独立于主项切换。
    /// 参数说明:
    /// - horizontal: 向左为负，向右为正；一次仅允许一个单位。
    /// - vertical: 向上为负，向下为正；与横向不能同时指定。
    /// 返回：只改变完整选择和视口，不写入虚拟空白或制造正文历史，失败保留原选择。
    public func extendRectangle(horizontal: Int = 0, vertical: Int = 0) {
        guard canExtendRectangle, (-1...1).contains(horizontal), (-1...1).contains(vertical),
            abs(horizontal) + abs(vertical) == 1,
            let state = viewSelectionState
        else {
            onStatus?("矩形扩展需要单选择或现存矩形，并先结束候选与编辑保护。")
            return
        }
        completionPanel?.hide()
        let fixed: SelectionEntry
        let active: SelectionEntry
        let fixedX: Double
        var activeX: Double
        if case .rectangle(let shape) = state.shape {
            let byID = Dictionary(
                uniqueKeysWithValues: state.entries.map {
                    ($0.id, $0)
                }
            )
            let fallback =
                state.primaryID == state.entries.first?.id
                ? state.entries.last ?? state.primary : state.entries.first ?? state.primary
            fixed =
                shape.anchorID.flatMap {
                    byID[$0]
                } ?? fallback
            active =
                shape.headID.flatMap {
                    byID[$0]
                } ?? state.primary
            fixedX = shape.anchorX
            activeX = shape.headX
        }
        else {
            fixed = state.primary
            active = state.primary
            fixedX = rectangleCaretX(at: fixed.selection.anchor, virtual: fixed.selection.virtualColumn)
            activeX = rectangleCaretX(at: active.selection.head, virtual: active.selection.virtualColumn)
        }
        let anchorRow = document.text.lineNumber(at: fixed.selection.anchor)
        var headRow = document.text.lineNumber(at: active.selection.head)
        if vertical != 0 {
            headRow = projection.adjacentLine(to: headRow, direction: vertical)
        }
        else {
            activeX = max(0, activeX + Double(horizontal) * rectangleColumnWidth)
        }
        guard setVisualRectangle(anchorRow: anchorRow, headRow: headRow, anchorX: fixedX, headX: activeX)
        else {
            return
        }
        refresh(reveal: true)
        onSelection?()
    }
}
