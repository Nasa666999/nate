import AppKit
import NateSearch

extension FindReplaceWindow {
    public var state: SearchWindowState {
        var result = SearchWindowState()
        result.options = options
        result.directory = directory.stringValue
        result.filters = filters.stringValue
        result.queryHistory = queryHistory
        result.replacementHistory = replaceHistory
        result.directoryHistory = directoryHistory
        result.filterHistory = filterHistory
        result.page = page
        result.stayAfterReplace = stayAfterReplace
        result.confirmsOpenReplacement = confirmsOpenReplacement
        result.presentation = presentationPreferences
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
        query.stringValue = state.options.query
        presentationPreferences = state.presentation
        replacement.stringValue = state.options.replacement
        directory.stringValue = state.directory
        filters.stringValue = state.filters
        queryHistory = state.queryHistory
        replaceHistory = state.replacementHistory
        directoryHistory = state.directoryHistory
        filterHistory = state.filterHistory
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
