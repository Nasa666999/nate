import AppKit
import NateCore

extension EditorView {
    /// 业务作用：仅向列操作提供当前正文和选择身份共同证明的真实矩形，普通多选不被推测为列键。
    /// 参数说明: 无。
    /// 返回：原矩形仍属于当前修订和选择时的完整目标，否则为空。
    public var rectangularSelections: [TextSelection]? {
        guard let rectangleEvidence, rectangleEvidence.revision == document.revision,
            rectangleEvidence.selection == selectionGeneration
        else {
            return nil
        }
        return viewSelections
    }

    /// 业务作用：区分真实零宽矩形与正宽但未覆盖字形的空键，避免后者扩大为行尾后缀。
    /// 参数说明: 无。
    /// 返回：当前矩形的真实零宽状态，形状证据过期或普通选择时为空。
    public var rectangleUsesSuffix: Bool? {
        rectangularSelections == nil ? nil : rectangleEvidence?.zeroWidth
    }

    /// 业务作用：完整验证并建立每行一个实际列目标，短行虚拟位置不写入正文。
    /// 参数说明:
    /// - selections: 按交互顺序的矩形行内目标，最多十万行。
    /// - zeroWidth: 可选的实际像素零宽形状；为空时按全部实际空范围判断。
    /// 返回：全部目标有效时更新选择和形状身份；跨行、重复行、候选或保护期间保留原选择。
    @discardableResult
    public func setRectangularSelections(_ selections: [TextSelection], zeroWidth: Bool? = nil) -> Bool {
        // 候选与保护仍持有当前输入或元数据，不能借列形状切换改变这份状态。
        guard composition == nil, !document.isEditingSuspended,
            !selections.isEmpty, selections.count <= 100_000
        else {
            return false
        }
        let empty = selections.allSatisfy {
            $0.range.isEmpty
        }
        let suffix = zeroWidth ?? empty
        guard !suffix || empty else {
            return false
        }
        var rows: Set<Int> = []
        for selection in selections {
            guard document.text.isBoundary(selection.anchor), document.text.isBoundary(selection.head),
                selection.virtualColumn >= 0
            else {
                return false
            }
            let row = document.text.lineNumber(at: selection.range.lower)
            let body = document.text.lineRange(row, includeEnding: false)
            guard selection.range.upper <= body.upper, rows.insert(row).inserted,
                selection.virtualColumn == 0 || selection.range.isEmpty && selection.head == body.upper
            else {
                return false
            }
        }
        // 即使几何位置相同，显式列选择仍是新的用户意图，旧排序不能借相同端点重新取得资格。
        viewSelections = selections
        selectionGeneration = UUID()
        rectangleEvidence = (selectionGeneration, document.revision, suffix)
        needsDisplay = true
        return true
    }

    /// 业务作用：普通移动或重新点击离开列选择，即使光标撞到边界也撤销旧形状与后台计划。
    /// 参数说明: 无。
    /// 返回：正文和几何选择保持原值，存在矩形时推进选择身份。
    func clearRectangularSelection() {
        if rectangleEvidence != nil {
            rectangleEvidence = nil
            selectionGeneration = UUID()
        }
    }
}
