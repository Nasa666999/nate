import AppKit
import NateSearch

extension FindReplaceWindow {
    /// 业务作用：只把当前已载入且可操作的面板计入项目搜索，停用的偏好不能伪装成已搜索范围。
    /// 参数说明: 无。
    /// 返回：按面板顺序排列的有效勾选项，未载入或忙碌面板不在其中。
    public var selectedProjectPanels: [Int] {
        projectChecks.indices.filter {
            availableProjectPanels.contains($0) && projectChecks[$0].state == .on
        }
    }

    /// 业务作用：识别项目范围选项的往返变化，旧请求不能借恢复相同外观重新取得执行权。
    /// 参数说明: 无。
    /// 返回：仅在本次窗口运行中有效的范围身份。
    public var projectRequestIdentity: UUID {
        projectRequestGeneration
    }

    /// 业务作用：应用定义的载入与忙碌状态只更新选择资格，不探测任何文件引用。
    /// 参数说明:
    /// - indices: 已载入且当前没有定义动作的面板索引。
    /// 返回：合法可用项更新；保留偏好，当前勾选集合变化时先撤销旧请求，未参与面板不影响原范围。
    public func setAvailableProjectPanels(_ indices: [Int]) {
        let available = Set(
            indices.filter {
                projectChecks.indices.contains($0)
            }
        )
        let previous = preferredProjectPanels.intersection(availableProjectPanels)
        let next = preferredProjectPanels.intersection(available)
        if previous != next {
            // 只有真正参与的集合改变才撤销动作，未参与面板的装卸不能中断当前查询。
            projectRequestGeneration = UUID()
            if page == .projects {
                onInputBegan?()
            }
        }
        availableProjectPanels = available
        updateProjectChoices()
    }

    /// 业务作用：项目后台计划同时复验输入原文、字段身份、页签与实际面板选择，防止旧范围继续发布或替换。
    /// 参数说明:
    /// - options: 发起时的完整搜索条件。
    /// - filters: 发起时的文件名过滤原文。
    /// - panels: 发起时真正可用的勾选面板。
    /// - identity: 发起时的范围身份。
    /// - inputs: 发起时四个完整输入的身份。
    /// 返回：所有输入证据仍属同一请求时为真，期间的往返修改也会撤销权限。
    public func matchesProjectRequest(
        options: SearchOptions,
        filters: String,
        panels: [Int],
        identity: UUID,
        inputs: [UUID]
    ) -> Bool {
        page == .projects && !isEditingInput && self.options == options
            && self.filters.stringValue.utf8.elementsEqual(filters.utf8)
            && selectedProjectPanels == panels && projectRequestGeneration == identity
            && contentIdentities == inputs
    }

    /// 业务作用：装配三个真实选择入口，用户未勾选范围前不授予查找或替换动作。
    /// 参数说明: 无。
    /// 返回：选择控件具有稳定面板索引，尚未载入的面板初始停用。
    func configureProjectChoices() {
        projectChoices.spacing = 14
        for (index, button) in projectChecks.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(projectChoiceChanged(_:))
            projectChoices.addArrangedSubview(button)
        }
        updateProjectChoices()
    }

    /// 业务作用：可见勾选状态只反映当前可用范围，保存偏好不会让未载入面板进入搜索。
    /// 参数说明: 无。
    /// 返回：面板选择与动作可用性同步，不修改搜索文本或用户文档。
    func updateProjectChoices() {
        for (index, button) in projectChecks.enumerated() {
            let available = availableProjectPanels.contains(index)
            button.isEnabled = available
            button.state = available && preferredProjectPanels.contains(index) ? .on : .off
            button.title = "项目面板 \(index + 1)" + (available ? "" : "（不可用）")
        }
        for case let button as NSButton in projectActions.arrangedSubviews {
            button.isEnabled = !selectedProjectPanels.isEmpty
        }
    }

    /// 业务作用：用户勾选只影响项目搜索范围，独立面板定义和正文不随选择改变。
    /// 参数说明:
    /// - sender: 用户刚操作的可用面板控件。
    /// 返回：合法偏好保存并撤销旧范围，停用控件无法扩大实际搜索集合。
    @objc func projectChoiceChanged(_ sender: NSButton) {
        // 控件身份和当前载入资格必须同时成立，旧事件不能重新启用已经卸载的面板。
        guard projectChecks.indices.contains(sender.tag), projectChecks[sender.tag] === sender,
            availableProjectPanels.contains(sender.tag)
        else {
            return
        }
        if sender.state == .on {
            preferredProjectPanels.insert(sender.tag)
        }
        else {
            preferredProjectPanels.remove(sender.tag)
        }
        projectRequestGeneration = UUID()
        onInputBegan?()
        updateProjectChoices()
        stateChanged()
    }
}
