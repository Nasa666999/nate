import Foundation

extension DocumentBuffer {
    /// 业务作用：同时固定当前正文、颜色集合与标记身份，后台计划不能用旧颜色覆盖用户后来的清除或添加。
    /// 参数说明: 无。
    /// 返回：仅结构共享正文的不可变标记输入，不改变修订与历史。
    public var markSnapshot: DocumentMarkSnapshot {
        DocumentMarkSnapshot(document: snapshot, generation: markGeneration, marks: marks)
    }

    /// 业务作用：原子发布后台准备的标记集合，颜色变化不构成保存内容或正文撤销项。
    /// 参数说明:
    /// - plan: 绑定原文档、正文修订和颜色身份的完整计划。
    /// 返回：当前颜色组的实际范围数；过期或退出保护时失败，正文、书签和撤销历史保持不变。
    @discardableResult
    public func commitMarks(_ plan: PreparedDocumentMarks) throws -> Int {
        // 退出保护和双重状态身份必须在发布前同时成立，清除再恢复也不能复活旧计划。
        guard !isEditingSuspended, plan.documentID == id, plan.revision == revision,
            plan.generation == markGeneration
        else {
            throw NateError.staleRevision
        }
        marks = plan.state
        markGeneration = UUID()
        return plan.count
    }

    /// 业务作用：用户明确清除指定颜色或全部颜色，书签与正文继续独立存在。
    /// 参数说明:
    /// - style: 指定颜色组，空值表示全部持久标记。
    /// 返回：移除的实际标记数；保护期间不改变状态，空集合的明确清除仍撤销旧后台计划。
    @discardableResult
    public func clearMarks(_ style: DocumentMarkStyle? = nil) -> Int {
        // 关闭收束后的视图元数据不能继续被迟到动作改变。
        guard !isEditingSuspended else {
            return 0
        }
        let before = marks.count
        marks = marks.removing(style)
        markGeneration = UUID()
        return before - marks.count
    }

    /// 业务作用：正文与历史发布前完整准备当前颜色，行移动失败不能留下一半正文与旧颜色。
    /// 参数说明:
    /// - positions: 本次实际发布的前向或反向位置变换。
    /// - text: 这次动作即将发布的完整正文。
    /// 返回：当前仍保留的颜色按原文移动，不从历史恢复已清除样式；超量或取消时整体失败。
    func prepareDocumentMarkMapping(_ positions: PositionMap, in text: PieceTree) throws -> DocumentMarkState
    {
        guard positions.changeCount > 0, marks.count > 0 else {
            return marks
        }
        if let permutation = positions.permutation {
            return try marks.relocated(by: permutation, in: text)
        }
        return marks.mapped(through: positions)
    }

    /// 业务作用：完整正文与颜色都已准备成功后更新当前标记，不在发布阶段重新执行可失败的大范围映射。
    /// 参数说明:
    /// - state: 本次实际正文对应的完整颜色状态。
    /// 返回：颜色真正变化时推进其独立身份，当前清除意图始终保留。
    func publishDocumentMarks(_ state: DocumentMarkState) {
        if state != marks {
            marks = state
            markGeneration = UUID()
        }
    }
}
