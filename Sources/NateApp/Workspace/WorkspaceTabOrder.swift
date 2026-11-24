import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：只在原标签集合和顺序仍一致时发布元数据重排，活动正文和候选输入不被切换或确认。
    /// 参数说明:
    /// - move: 用户明确手势或上下文菜单产生的完整原顺序计划。
    /// 返回：完整接受或顺序原本未变时为真；退出、关闭中或旧来源时保留全部原顺序。
    @discardableResult
    func reorderTabs(_ move: DocumentOrderMove) -> Bool {
        // 退出或关闭已经固定文档保护范围，旧手势不能在其间重写工作区索引来源。
        guard !closing,
            !documents.contains(where: {
                $0.closing
            }),
            let sourceGeneration = move.sourceGeneration, let window = mainWindow,
            sourceGeneration == window.tabOrderIdentity,
            workspaceTabIDs(in: window) == move.original
        else {
            mainWindow?.status.stringValue = "标签集合或原顺序已改变，旧移动未执行。"
            return false
        }
        guard move.result != move.original else {
            return true
        }
        let key = ObjectIdentifier(window)
        if windowTabGroups[key] != nil {
            // 分组内重排只更新这扇窗口，其他窗口曾建立的独立顺序继续有效。
            windowTabGroups[key] = move.result
            refreshUI()
            return true
        }
        let byID = Dictionary(
            uniqueKeysWithValues: documents.map {
                ($0.buffer.id, $0)
            }
        )
        let reordered = move.result.compactMap {
            byID[$0]
        }
        guard reordered.count == documents.count else {
            return false
        }
        // 只发布相同对象的新排列，原文件写入者、克隆、完整选择和活动身份仍由原实例持有。
        documents = reordered
        refreshUI()
        scheduleRecovery()
        return true
    }

    /// 业务作用：非活动标签的明确重排菜单以被点击身份为依据，不先切换正文或确认候选。
    /// 参数说明:
    /// - documentID: 菜单绑定的原标签身份。
    /// - action: 左移、右移、首位或末位的明确指令。
    /// 返回：合法指令按当前完整顺序建立计划，边界无变化保持原状态，旧身份不产生动作。
    func moveTab(_ documentID: UUID, action: String) {
        let order = workspaceTabIDs(in: mainWindow)
        guard let index = order.firstIndex(of: documentID) else {
            return
        }
        let before: UUID?
        switch action {
        case "moveTabLeft":
            before = index > 0 ? order[index - 1] : documentID
        case "moveTabRight":
            before = index + 2 < order.count ? order[index + 2] : nil
        case "moveTabFirst":
            before = order.first
        case "moveTabLast":
            before = nil
        default:
            return
        }
        do {
            let move = try DocumentOrderMove(
                original: order,
                documentID: documentID,
                before: before,
                sourceGeneration: mainWindow?.tabOrderIdentity
            )
            _ = reorderTabs(move)
        }
        catch {
            mainWindow?.status.stringValue = error.localizedDescription
        }
    }
}
