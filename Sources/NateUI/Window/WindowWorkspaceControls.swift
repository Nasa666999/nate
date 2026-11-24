import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：窗口菜单读取自身真实浮动层级。
    /// 参数说明: 无。
    /// 返回：编辑窗口处于置顶层时为真。
    public var isWorkspaceWindowOnTop: Bool {
        window?.level == .floating
    }

    /// 业务作用：切换当前窗口与桌面普通窗口的层级关系，浮动工具继续由原编辑窗口管理。
    /// 参数说明:
    /// - enabled: 用户是否要求当前编辑窗口置顶。
    /// 返回：原生窗口采用明确层级，其他窗口的设置不受影响。
    public func setWorkspaceWindowOnTop(_ enabled: Bool) {
        window?.level = enabled ? .floating : .normal
    }

    /// 业务作用：工具栏临时可见状态由所属窗口持有。
    /// 参数说明: 无。
    /// 返回：工具栏占用工作区位置时为真。
    public var isWorkspaceToolbarVisible: Bool {
        !toolbarContainer.isHidden
    }

    /// 业务作用：在当前窗口暂时收起或恢复工具栏，剩余区域继续呈现标签和实际正文。
    /// 参数说明:
    /// - visible: 当前窗口是否显示工具栏。
    /// 返回：原生区域实际释放或重新占用空间，独立视口和正文编辑证据得以保留。
    public func setWorkspaceToolbarVisible(_ visible: Bool) {
        guard visible != isWorkspaceToolbarVisible else {
            return
        }
        let viewports = editorSplit.arrangedSubviews.compactMap {
            view -> (EditorView, EditorViewportAnchor?)? in
            guard let editor = (view as? NSScrollView)?.documentView as? EditorView else {
                return nil
            }
            return (editor, editor.viewportAnchor())
        }
        scrollSynchronization.preserveIndependentViewports {
            // 布局改变时先暂停滚动互相传播，再分别还原原视图位置，避免覆盖另一分屏的顶行。
            toolbarContainer.isHidden = !visible
            toolbarHeight.constant = visible ? Self.toolbarVisibleHeight : 0
            window?.contentView?.layoutSubtreeIfNeeded()
            refreshEditors()
            for (editor, viewport) in viewports {
                editor.restoreViewportAnchor(viewport)
            }
        }
    }

    /// 业务作用：将原生键盘焦点交给当前窗口的另一实际可见正文分屏。
    /// 参数说明: 无。
    /// 返回：存在另一编辑视图且原输入安全交接时为真，其余状态保留当前焦点。
    @discardableResult
    public func focusOtherEditorPane() -> Bool {
        guard let window, window.attachedSheet == nil, !searchResults.isEditingInput,
            let destination = editorSplit.arrangedSubviews.lazy.compactMap({
                ($0 as? NSScrollView)?.documentView as? EditorView
            }).first(where: {
                $0 !== editor && $0.window === window
            })
        else {
            return false
        }
        // AppKit 通过原编辑器的收束入口交接候选，失败时不能擅自登记另一编辑视图。
        guard window.makeFirstResponder(destination) else {
            return false
        }
        restoreEditorFocusFromFloatingPanel()
        return true
    }
}
