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

    /// 业务作用：每次正文事务、撤销和重做只移动当前仍保留的标记，不从旧历史重新创建被用户清除的颜色。
    /// 参数说明:
    /// - positions: 本次实际发布的前向或反向位置变换。
    /// 返回：标记随原文本移动，完全消失的非空范围移除；位置变化更新颜色身份，不增加正文历史。
    func mapDocumentMarks(_ positions: PositionMap) {
        guard positions.changeCount > 0, marks.count > 0 else {
            return
        }
        let mapped = marks.mapped(through: positions)
        if mapped != marks {
            marks = mapped
            markGeneration = UUID()
        }
    }
}
