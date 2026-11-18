import AppKit
import NateSearch

extension FindReplaceWindow {
    /// 业务作用：窗口外的文件导航通过轻量输入身份识别新查询意图，不保留或比较完整搜索原文。
    /// 参数说明: 无。
    /// 返回：查找、替换、目录及过滤字段的当前运行期身份，顺序固定，不产生持久化副作用。
    public var inputIdentities: [UUID] {
        [
            query.navigationIdentity, replacement.navigationIdentity, directory.navigationIdentity,
            filters.navigationIdentity,
        ]
    }

    /// 业务作用：原生短字段与完整输入摘要使用同一提交入口，项目页执行所选集合，其余页按方向导航。
    /// 参数说明:
    /// - reversing: 是否临时反转已保存的查找方向。
    /// 返回：项目页提交完整集合查询，其余页按当前方向提交；反向选项本身保持原值。
    func submitFromInput(reversing: Bool) {
        if page == .projects {
            submit("projects")
            return
        }
        var previous = backwards.state == .on
        if reversing {
            previous.toggle()
        }
        submit(previous ? "previous" : "next")
    }

    /// 业务作用：原生字段和长输入摘要共用取消入口，先保存已确认条件再交还正文焦点。
    /// 参数说明: 无。
    /// 返回：搜索面板隐藏，当前输入保留，候选确认由调用者的输入上下文门禁优先处理。
    func cancelFromInput() {
        stateChanged()
        window?.orderOut(nil)
        onDismiss?()
    }

    public var state: SearchWindowState {
        var result = SearchWindowState()
        result.options = options
        // 退出或选项变化可能发生在候选期间；归档只记录确认原文，不把候选或全文草稿变成下次启动的查询。
        result.options.query = query.committedStringValue
        result.options.replacement = replacement.committedStringValue
        result.directory = directory.committedStringValue
        result.filters = filters.committedStringValue
        result.queryHistory = queryHistory
        result.replacementHistory = replaceHistory
        result.directoryHistory = directoryHistory
        result.filterHistory = filterHistory
        result.page = page
        result.stayAfterReplace = stayAfterReplace
        result.confirmsOpenReplacement = confirmsOpenReplacement
        result.presentation = presentationPreferences
        result.inputFont = inputFontConfiguration
        result.projectPanels = preferredProjectPanels.sorted()
        return result
    }

    /// 业务作用：启动时恢复完整搜索配置，历史原文不经过菜单标签，恢复期间不触发递归保存。
    /// 参数说明:
    /// - state: 已读取且需要再次校验的配置快照。
    /// 返回：合法配置完整进入控件；无效格式或超限在改变任何输入前失败。
    public func restore(_ state: SearchWindowState) throws {
        // 未知格式和过量输入必须在第一个控件赋值前拒绝，不能留下部分恢复的请求条件。
        try state.validate()
        restoringState = true
        defer {
            restoringState = false
        }
        try applyInputFont(state.inputFont, notify: false)
        query.stringValue = state.options.query
        presentationPreferences = state.presentation
        replacement.stringValue = state.options.replacement
        directory.stringValue = state.directory
        filters.stringValue = state.filters
        queryHistory = state.queryHistory
        replaceHistory = state.replacementHistory
        directoryHistory = state.directoryHistory
        filterHistory = state.filterHistory
        preferredProjectPanels = Set(state.projectPanels)
        updateProjectChoices()
        for (input, values) in [
            (query, queryHistory), (replacement, replaceHistory),
            (directory, directoryHistory), (filters, filterHistory),
        ] {
            input.removeAllItems()
            input.addItems(withObjectValues: values)
        }
        mode.selectItem(at: SearchMode.allCases.firstIndex(of: state.options.mode) ?? 0)
        for (button, enabled) in [
            (caseSensitive, state.options.caseSensitive), (wholeWord, state.options.wholeWord),
            (dot, state.options.dotMatchesNewline), (backwards, state.options.backwards),
            (wrap, state.options.wrap), (selection, state.options.selectionOnly),
            (recursive, state.options.recursive), (includeHidden, state.options.includeHidden),
            (diskBuffers, state.options.ignoreOpenBuffers), (stay, state.stayAfterReplace),
            (confirmOpen, state.confirmsOpenReplacement),
        ] {
            button.state = enabled ? .on : .off
        }
        modeChanged()
        selectPage(state.page, focus: false)
    }

    /// 业务作用：只发布用户当前状态，恢复动作和未装配持久化的独立窗口不触发文件副作用。
    /// 参数说明: 无。
    /// 返回：已装配的保存入口接收不可变配置快照。
    func stateChanged() {
        guard !restoringState else {
            return
        }
        onStateChange?(state)
    }

    /// 业务作用：勾选选项后同步当前持久配置，不启动正文搜索或修改文档。
    /// 参数说明: 无。
    /// 返回：选项快照进入配置保存入口。
    @objc func optionsChanged() {
        projectRequestGeneration = UUID()
        stateChanged()
    }

    /// 业务作用：关闭搜索面板时保留尚未执行的输入与选项。
    /// 参数说明:
    /// - notification: 当前窗口关闭通知。
    /// 返回：完整状态进入保存入口，正文与搜索结果不变。
    public func windowWillClose(_ notification: Notification) {
        stateChanged()
    }

    /// 业务作用：让用户显式允许用当前完整设置重新建立归档，读取失败时也不自动覆盖未知内容。
    /// 参数说明: 无。
    /// 返回：确认后请求重新取得磁盘基线再保存；取消保留已有归档。
    @objc func resetSavedSettings() {
        let alert = NSAlert()
        alert.messageText = "重新保存当前搜索设置？"
        alert.informativeText = "将以当前输入、历史、模式及选项覆盖已保存的搜索设置。"
        alert.addButton(withTitle: "重新保存")
        alert.addButton(withTitle: "取消")
        // 重新取得磁盘基线会授予覆盖当前归档的资格，只能由这次明确确认启动。
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        onResetSavedState?(state)
    }
}
